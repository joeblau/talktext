import Carbon.HIToolbox
import Combine
import os

private let hotKeyLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "hotkey")

enum HotKeyInstallationError: Error, Equatable, Sendable {
    case handlerRegistrationFailed(OSStatus)
    case shortcutRegistrationFailed(OSStatus)
    case cleanupFailed(HotKeyCleanupError)
}

enum HotKeyCleanupError: Error, Equatable, Sendable {
    case shortcutUnregistrationFailed(OSStatus)
    case handlerRemovalFailed(OSStatus)
}

enum HotKeyAvailability: Equatable, Sendable {
    case unregistered
    case registered
    case handlerRegistrationFailed(OSStatus)
    case shortcutRegistrationFailed(OSStatus)
    case cleanupFailed(HotKeyCleanupError)

    var isRegistered: Bool {
        self == .registered
    }

    var recoveryMessage: String? {
        switch self {
        case .registered:
            nil
        case .unregistered:
            "Ctrl+Space is not registered. The menu button still works."
        case let .handlerRegistrationFailed(status):
            "The Ctrl+Space event handler could not start (error \(status)). The menu button still works; retry the shortcut."
        case let .shortcutRegistrationFailed(status):
            "Ctrl+Space is unavailable (error \(status)). The menu button still works; disable any conflicting shortcut, then retry."
        case let .cleanupFailed(.shortcutUnregistrationFailed(status)):
            "The previous Ctrl+Space shortcut could not be released (error \(status)). The menu button still works; retry before registering it again."
        case let .cleanupFailed(.handlerRemovalFailed(status)):
            "The previous Ctrl+Space event handler could not be removed (error \(status)). The menu button still works; retry before registering it again."
        }
    }
}

@MainActor
protocol GlobalHotKeyService: AnyObject {
    func install(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotKeyInstallationError>

    func uninstall() -> Result<Void, HotKeyCleanupError>
}

@MainActor
final class HotKeyController: ObservableObject {
    @Published private(set) var availability: HotKeyAvailability = .unregistered

    private let service: any GlobalHotKeyService
    private var action: (@MainActor @Sendable () -> Void)?

    init() {
        service = CarbonGlobalHotKeyService()
    }

    init(service: any GlobalHotKeyService) {
        self.service = service
    }

    func register(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        installSavedAction()
    }

    func retry() {
        guard action != nil else {
            availability = .unregistered
            return
        }

        installSavedAction()
    }

    @discardableResult
    func unregister() -> Result<Void, HotKeyCleanupError> {
        let result = service.uninstall()
        switch result {
        case .success:
            availability = .unregistered
            action = nil
        case let .failure(error):
            availability = .cleanupFailed(error)
            logCleanupFailure(error)
        }
        return result
    }

    private func installSavedAction() {
        guard let action else {
            availability = .unregistered
            return
        }

        // A retry or replacement only proceeds from a clean Carbon lifecycle.
        switch service.uninstall() {
        case .success:
            break
        case let .failure(error):
            availability = .cleanupFailed(error)
            logCleanupFailure(error)
            return
        }

        switch service.install(action: action) {
        case .success:
            availability = .registered
            hotKeyLogger.notice("Global hotkey registered")
        case let .failure(.handlerRegistrationFailed(status)):
            availability = .handlerRegistrationFailed(status)
            hotKeyLogger.error("Hotkey event handler registration failed: \(status)")
        case let .failure(.shortcutRegistrationFailed(status)):
            availability = .shortcutRegistrationFailed(status)
            hotKeyLogger.error("Global shortcut registration failed: \(status)")
        case let .failure(.cleanupFailed(error)):
            availability = .cleanupFailed(error)
            logCleanupFailure(error)
        }
    }

    private func logCleanupFailure(_ error: HotKeyCleanupError) {
        switch error {
        case let .shortcutUnregistrationFailed(status):
            hotKeyLogger.error("Global shortcut cleanup failed: \(status)")
        case let .handlerRemovalFailed(status):
            hotKeyLogger.error("Hotkey event handler cleanup failed: \(status)")
        }
    }
}

struct CarbonHandleResult<Handle> {
    let status: OSStatus
    let handle: Handle?
}

@MainActor
protocol CarbonHotKeyAPI: AnyObject {
    func installEventHandler(
        context: UnsafeMutableRawPointer
    ) -> CarbonHandleResult<EventHandlerRef>

    func registerEventHotKey(
        options: OptionBits
    ) -> CarbonHandleResult<EventHotKeyRef>

    func unregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus
    func removeEventHandler(_ eventHandler: EventHandlerRef) -> OSStatus
}

@MainActor
final class CarbonGlobalHotKeyService: GlobalHotKeyService {
    private let api: any CarbonHotKeyAPI
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callbackContext: CarbonHotKeyCallbackContext?

    init() {
        api = SystemCarbonHotKeyAPI()
    }

    init(api: any CarbonHotKeyAPI) {
        self.api = api
    }

    func install(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        switch uninstall() {
        case .success:
            break
        case let .failure(error):
            return .failure(.cleanupFailed(error))
        }

        let context = CarbonHotKeyCallbackContext(action: action)
        let handlerResult = api.installEventHandler(
            context: Unmanaged.passUnretained(context).toOpaque()
        )

        if let installedHandler = handlerResult.handle {
            eventHandler = installedHandler
            callbackContext = context
        }

        guard handlerResult.status == noErr, handlerResult.handle != nil else {
            let failure = HotKeyInstallationError.handlerRegistrationFailed(
                normalizedFailureStatus(handlerResult.status)
            )
            guard eventHandler != nil else {
                return .failure(failure)
            }

            switch uninstall() {
            case .success:
                return .failure(failure)
            case let .failure(error):
                return .failure(.cleanupFailed(error))
            }
        }

        let shortcutResult = api.registerEventHotKey(
            options: OptionBits(kEventHotKeyExclusive)
        )

        if let registeredHotKey = shortcutResult.handle {
            hotKey = registeredHotKey
        }

        guard shortcutResult.status == noErr, shortcutResult.handle != nil else {
            let failure = HotKeyInstallationError.shortcutRegistrationFailed(
                normalizedFailureStatus(shortcutResult.status)
            )
            switch uninstall() {
            case .success:
                return .failure(failure)
            case let .failure(error):
                return .failure(.cleanupFailed(error))
            }
        }

        return .success(())
    }

    func uninstall() -> Result<Void, HotKeyCleanupError> {
        if let hotKey {
            let status = api.unregisterEventHotKey(hotKey)
            if status != noErr {
                hotKeyLogger.error("Global shortcut cleanup failed: \(status)")
                return .failure(.shortcutUnregistrationFailed(status))
            }
            self.hotKey = nil
        }

        if let eventHandler {
            let status = api.removeEventHandler(eventHandler)
            if status != noErr {
                hotKeyLogger.error("Hotkey event handler cleanup failed: \(status)")
                return .failure(.handlerRemovalFailed(status))
            }
            self.eventHandler = nil
        }

        callbackContext = nil
        return .success(())
    }

    private func normalizedFailureStatus(_ status: OSStatus) -> OSStatus {
        status == noErr ? OSStatus(eventInternalErr) : status
    }
}

@MainActor
private final class SystemCarbonHotKeyAPI: CarbonHotKeyAPI {
    private static let signature = OSType(0x54545854) // "TTXT"
    private static let identifier: UInt32 = 1

    func installEventHandler(
        context: UnsafeMutableRawPointer
    ) -> CarbonHandleResult<EventHandlerRef> {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            context,
            &eventHandler
        )
        return CarbonHandleResult(status: status, handle: eventHandler)
    }

    func registerEventHotKey(
        options: OptionBits
    ) -> CarbonHandleResult<EventHotKeyRef> {
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            options,
            &hotKey
        )
        return CarbonHandleResult(status: status, handle: hotKey)
    }

    func unregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(hotKey)
    }

    func removeEventHandler(_ eventHandler: EventHandlerRef) -> OSStatus {
        RemoveEventHandler(eventHandler)
    }
}

private final class CarbonHotKeyCallbackContext: @unchecked Sendable {
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func invoke() {
        Task { @MainActor in
            action()
        }
    }
}

private func carbonHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let context = Unmanaged<CarbonHotKeyCallbackContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    context.invoke()
    return noErr
}
