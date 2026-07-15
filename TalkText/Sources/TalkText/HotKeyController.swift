import Carbon.HIToolbox
import Combine
import os

private let hotKeyLogger = Logger(subsystem: "com.joeblau.talktext", category: "hotkey")

enum HotKeyInstallationError: Error, Equatable, Sendable {
    case handlerRegistrationFailed(OSStatus)
    case shortcutRegistrationFailed(OSStatus)
}

enum HotKeyAvailability: Equatable, Sendable {
    case unregistered
    case registered
    case handlerRegistrationFailed(OSStatus)
    case shortcutRegistrationFailed(OSStatus)

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
        }
    }
}

@MainActor
protocol GlobalHotKeyService: AnyObject {
    func install(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotKeyInstallationError>

    func uninstall()
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

    func unregister() {
        service.uninstall()
        availability = .unregistered
        action = nil
    }

    private func installSavedAction() {
        guard let action else {
            availability = .unregistered
            return
        }

        // A retry or replacement always starts from a clean Carbon lifecycle.
        service.uninstall()

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
        }
    }
}

@MainActor
final class CarbonGlobalHotKeyService: GlobalHotKeyService {
    private static let signature = OSType(0x54545854) // "TTXT"
    private static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callbackContext: CarbonHotKeyCallbackContext?

    func install(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        uninstall()

        let context = CarbonHotKeyCallbackContext(action: action)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(context).toOpaque(),
            &installedHandler
        )

        guard handlerStatus == noErr, let installedHandler else {
            if let installedHandler {
                RemoveEventHandler(installedHandler)
            }
            return .failure(.handlerRegistrationFailed(handlerStatus))
        }

        eventHandler = installedHandler
        callbackContext = context

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        var registeredHotKey: EventHotKeyRef?
        let shortcutStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard shortcutStatus == noErr, let registeredHotKey else {
            uninstall()
            return .failure(.shortcutRegistrationFailed(shortcutStatus))
        }

        hotKey = registeredHotKey
        return .success(())
    }

    func uninstall() {
        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            if status != noErr {
                hotKeyLogger.error("Global shortcut cleanup failed: \(status)")
            }
            self.hotKey = nil
        }

        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            if status != noErr {
                hotKeyLogger.error("Hotkey event handler cleanup failed: \(status)")
            }
            self.eventHandler = nil
        }

        callbackContext = nil
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
