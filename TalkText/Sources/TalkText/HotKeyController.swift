import AppKit
import Combine
import Foundation
import os

private let hotKeyLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "hotkey")

/// `NX_DEVICERALTKEYMASK`: the device-dependent bit that separates the right
/// Option key from the left one in a `flagsChanged` event.
private let rightOptionModifierMask: UInt = 0x40

enum RightOptionKeyPhase: Equatable, Sendable {
    case pressed
    case released
}

enum RecordingIntent: Equatable, Sendable {
    case start
    case stop
}

enum HotKeyInstallationError: Error, Equatable, Sendable {
    case monitorRegistrationFailed
}

enum HotKeyAvailability: Equatable, Sendable {
    case unregistered
    case registered
    case monitorRegistrationFailed

    var isRegistered: Bool {
        self == .registered
    }

    var recoveryMessage: String? {
        switch self {
        case .registered:
            nil
        case .unregistered:
            "Right Option recording is not active. The menu button still works."
        case .monitorRegistrationFailed:
            "Right Option recording could not start. Enable Accessibility access, then retry."
        }
    }
}

@MainActor
protocol GlobalHotKeyService: AnyObject {
    func install(
        action: @escaping @MainActor @Sendable (RightOptionKeyPhase) -> Void
    ) -> Result<Void, HotKeyInstallationError>

    func uninstall()
}

/// Delays the hold decision: a press only becomes a recording once the key has
/// stayed down long enough to rule out a tap.
@MainActor
protocol HoldTimerScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

/// Converts global right-Option transitions into two recording gestures.
/// Holding the key records for as long as it is held; two quick taps latch
/// recording on until the next press stops it. A single tap does nothing, so
/// right Option stays usable as an ordinary modifier.
@MainActor
final class HotKeyController: ObservableObject {
    @Published private(set) var availability: HotKeyAvailability = .unregistered

    private enum GestureState: Equatable {
        case idle
        case pendingHold(startedAt: TimeInterval)
        case awaitingSecondTap(deadline: TimeInterval)
        case holding
        case latched
        case ignoringUntilRelease
    }

    private let service: any GlobalHotKeyService
    private let holdTimer: any HoldTimerScheduling
    private let holdThreshold: TimeInterval
    private let doubleTapInterval: TimeInterval
    private let now: @MainActor @Sendable () -> TimeInterval
    private var action: (@MainActor @Sendable (RecordingIntent) -> Void)?
    private var state: GestureState = .idle

    init() {
        service = SystemRightOptionKeyService()
        holdTimer = SystemHoldTimer()
        holdThreshold = 0.25
        doubleTapInterval = max(0.25, NSEvent.doubleClickInterval)
        now = { ProcessInfo.processInfo.systemUptime }
    }

    init(
        service: any GlobalHotKeyService,
        holdTimer: any HoldTimerScheduling = SystemHoldTimer(),
        holdThreshold: TimeInterval = 0.25,
        doubleTapInterval: TimeInterval = 0.35,
        now: @escaping @MainActor @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.service = service
        self.holdTimer = holdTimer
        self.holdThreshold = max(0.05, holdThreshold)
        self.doubleTapInterval = max(0.1, doubleTapInterval)
        self.now = now
    }

    func register(
        action: @escaping @MainActor @Sendable (RecordingIntent) -> Void
    ) {
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
        resetGesture()
        availability = .unregistered
        action = nil
    }

    /// Recorder failures and the maximum-duration limit can end a session
    /// without another right-Option event. Reset so the next press starts
    /// normally.
    func recordingSessionDidEnd() {
        resetGesture()
    }

    private func installSavedAction() {
        guard action != nil else {
            availability = .unregistered
            return
        }

        service.uninstall()
        resetGesture()
        switch service.install(action: { [weak self] phase in
            self?.handle(phase, at: self?.now() ?? 0)
        }) {
        case .success:
            availability = .registered
            hotKeyLogger.notice("Global right-Option recording monitor registered")
        case .failure(.monitorRegistrationFailed):
            availability = .monitorRegistrationFailed
            hotKeyLogger.error("Global right-Option recording monitor registration failed")
        }
    }

    private func handle(_ phase: RightOptionKeyPhase, at timestamp: TimeInterval) {
        switch phase {
        case .pressed:
            handlePress(at: timestamp)
        case .released:
            handleRelease(at: timestamp)
        }
    }

    private func handlePress(at timestamp: TimeInterval) {
        switch state {
        case .idle:
            beginPendingHold(at: timestamp)
        case .pendingHold, .holding, .ignoringUntilRelease:
            break
        case let .awaitingSecondTap(deadline):
            if timestamp <= deadline {
                state = .latched
                action?(.start)
            } else {
                beginPendingHold(at: timestamp)
            }
        case .latched:
            state = .ignoringUntilRelease
            action?(.stop)
        }
    }

    private func handleRelease(at timestamp: TimeInterval) {
        switch state {
        case .idle, .awaitingSecondTap, .latched:
            break
        case .pendingHold:
            holdTimer.cancel()
            state = .awaitingSecondTap(deadline: timestamp + doubleTapInterval)
        case .holding:
            state = .idle
            action?(.stop)
        case .ignoringUntilRelease:
            state = .idle
        }
    }

    private func beginPendingHold(at timestamp: TimeInterval) {
        state = .pendingHold(startedAt: timestamp)
        holdTimer.schedule(after: holdThreshold) { [weak self] in
            self?.holdThresholdElapsed()
        }
    }

    private func holdThresholdElapsed() {
        guard case .pendingHold = state else {
            return
        }

        state = .holding
        action?(.start)
    }

    private func resetGesture() {
        holdTimer.cancel()
        state = .idle
    }
}

@MainActor
final class SystemHoldTimer: HoldTimerScheduling {
    private var pendingWork: DispatchWorkItem?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                action()
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pendingWork?.cancel()
        pendingWork = nil
    }
}

@MainActor
final class SystemRightOptionKeyService: GlobalHotKeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var callbackContext: RightOptionKeyMonitorContext?

    func install(
        action: @escaping @MainActor @Sendable (RightOptionKeyPhase) -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        uninstall()

        let context = RightOptionKeyMonitorContext(action: action)
        guard let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
            handler: { event in
                context.handle(modifierFlags: event.modifierFlags)
            }
        ) else {
            return .failure(.monitorRegistrationFailed)
        }

        guard let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: { event in
                context.handle(modifierFlags: event.modifierFlags)
                return event
            }
        ) else {
            NSEvent.removeMonitor(globalMonitor)
            return .failure(.monitorRegistrationFailed)
        }

        self.globalMonitor = globalMonitor
        self.localMonitor = localMonitor
        callbackContext = context
        return .success(())
    }

    func uninstall() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        callbackContext = nil
    }
}

private final class RightOptionKeyMonitorContext: @unchecked Sendable {
    private let lock = NSLock()
    private let action: @MainActor @Sendable (RightOptionKeyPhase) -> Void
    private var rightOptionIsDown = false

    init(action: @escaping @MainActor @Sendable (RightOptionKeyPhase) -> Void) {
        self.action = action
    }

    func handle(modifierFlags: NSEvent.ModifierFlags) {
        let rightOptionIsDown = modifierFlags.rawValue & rightOptionModifierMask != 0
        let phase = lock.withLock { () -> RightOptionKeyPhase? in
            guard rightOptionIsDown != self.rightOptionIsDown else {
                return nil
            }
            self.rightOptionIsDown = rightOptionIsDown
            return rightOptionIsDown ? .pressed : .released
        }
        guard let phase else {
            return
        }

        DispatchQueue.main.async { [action] in
            action(phase)
        }
    }
}
