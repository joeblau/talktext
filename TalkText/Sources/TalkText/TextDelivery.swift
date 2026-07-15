import ApplicationServices
import AppKit
import Foundation

struct PasteTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let launchDate: Date
    let bundleURL: URL?

    init?(processIdentifier: pid_t, bundleIdentifier: String?, launchDate: Date?, bundleURL: URL?) {
        guard let launchDate else {
            return nil
        }
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
        self.bundleURL = bundleURL
    }
}

enum TargetProcessAvailability: Equatable, Sendable {
    case available
    case exited
    case identityChanged
}

enum TargetActivationOutcome: Equatable, Sendable {
    case requested
    case targetExited
    case identityChanged
    case rejected
}

@MainActor
protocol WorkspaceServing: AnyObject {
    func currentExternalTarget(excludingBundleIdentifier: String?) -> PasteTarget?
    func availability(of target: PasteTarget) -> TargetProcessAvailability
    func activate(_ target: PasteTarget) -> TargetActivationOutcome
    func frontmostTarget() -> PasteTarget?
}

@MainActor
final class SystemWorkspaceService: WorkspaceServing {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func currentExternalTarget(excludingBundleIdentifier: String?) -> PasteTarget? {
        guard let application = workspace.frontmostApplication,
              application.bundleIdentifier != excludingBundleIdentifier else {
            return nil
        }
        return target(for: application)
    }

    func availability(of target: PasteTarget) -> TargetProcessAvailability {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return .exited
        }
        return targetMatches(target, application: application) ? .available : .identityChanged
    }

    func activate(_ target: PasteTarget) -> TargetActivationOutcome {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return .targetExited
        }
        guard targetMatches(target, application: application) else {
            return .identityChanged
        }
        return application.activate(options: [.activateAllWindows]) ? .requested : .rejected
    }

    func frontmostTarget() -> PasteTarget? {
        workspace.frontmostApplication.flatMap(target(for:))
    }

    private func target(for application: NSRunningApplication) -> PasteTarget? {
        PasteTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate,
            bundleURL: application.bundleURL
        )
    }

    private func targetMatches(_ target: PasteTarget, application: NSRunningApplication) -> Bool {
        Self.targetMatches(
            target,
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            launchDate: application.launchDate,
            bundleURL: application.bundleURL
        )
    }

    static func targetMatches(
        _ target: PasteTarget,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        launchDate: Date?,
        bundleURL: URL?
    ) -> Bool {
        guard let launchDate,
              processIdentifier == target.processIdentifier,
              bundleIdentifier == target.bundleIdentifier,
              launchDate == target.launchDate else {
            return false
        }
        if target.bundleURL != nil || bundleURL != nil {
            guard target.bundleURL?.standardizedFileURL == bundleURL?.standardizedFileURL else {
                return false
            }
        }
        return true
    }
}

enum AccessibilityInsertionOutcome: Equatable, Sendable {
    case inserted
    case targetNotFocused
    case noFocusedElement
    case valueNotWritable
    case failed(errorCode: Int32)
}

enum TargetWindowAvailability: Equatable, Sendable {
    case available
    case closed
    case unavailable(errorCode: Int32)
}

@MainActor
protocol AccessibilityServing: AnyObject {
    func ensurePermission(prompt: Bool) -> Bool
    func insert(_ text: String, into target: PasteTarget) -> AccessibilityInsertionOutcome
    func windowAvailability(of target: PasteTarget) -> TargetWindowAvailability
}

@MainActor
final class SystemAccessibilityService: AccessibilityServing {
    func ensurePermission(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String, into target: PasteTarget) -> AccessibilityInsertionOutcome {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard focusError == .success, let focusedElementValue else {
            return focusError == .success
                ? .noFocusedElement
                : .failed(errorCode: focusError.rawValue)
        }

        let focusedElement = unsafeDowncast(focusedElementValue, to: AXUIElement.self)
        var focusedProcessIdentifier: pid_t = 0
        let pidError = AXUIElementGetPid(focusedElement, &focusedProcessIdentifier)
        guard pidError == .success else {
            return .failed(errorCode: pidError.rawValue)
        }
        guard focusedProcessIdentifier == target.processIdentifier else {
            return .targetNotFocused
        }

        var valueSettable = DarwinBoolean(false)
        let valueSettableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueSettable
        )
        guard valueSettableError == .success else {
            return .failed(errorCode: valueSettableError.rawValue)
        }
        guard valueSettable.boolValue else {
            return .valueNotWritable
        }

        var currentValueRef: CFTypeRef?
        let currentValueError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValueRef
        )
        guard currentValueError == .success else {
            return .failed(errorCode: currentValueError.rawValue)
        }

        let currentValue = (currentValueRef as? String) ?? ""
        let currentNSString = currentValue as NSString
        let insertedNSString = text as NSString
        var selectedRange = copySelectedTextRange(from: focusedElement)
            ?? CFRange(location: currentNSString.length, length: 0)
        selectedRange.location = max(0, min(selectedRange.location, currentNSString.length))
        selectedRange.length = max(
            0,
            min(selectedRange.length, currentNSString.length - selectedRange.location)
        )
        let replacementRange = NSRange(
            location: selectedRange.location,
            length: selectedRange.length
        )
        let updatedValue = currentNSString.replacingCharacters(
            in: replacementRange,
            with: text
        )
        let setValueError = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueError == .success else {
            return .failed(errorCode: setValueError.rawValue)
        }
        var insertionRange = CFRange(
            location: selectedRange.location + insertedNSString.length,
            length: 0
        )
        if let insertionValue = AXValueCreate(.cfRange, &insertionRange) {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                insertionValue
            )
        }
        return .inserted
    }

    func windowAvailability(of target: PasteTarget) -> TargetWindowAvailability {
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard result == .success else {
            return .unavailable(errorCode: result.rawValue)
        }
        guard let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            return .closed
        }
        return .available
    }

    private func copySelectedTextRange(from element: AXUIElement) -> CFRange? {
        var selectedRangeRef: CFTypeRef?
        let selectionError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard selectionError == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = unsafeDowncast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
    }
}

@MainActor
protocol PasteEventPosting: AnyObject {
    func ensurePermission(prompt: Bool) -> Bool
    func postPasteShortcut(to target: PasteTarget) -> Bool
}

@MainActor
final class SystemPasteEventPoster: PasteEventPosting {
    func ensurePermission(prompt: Bool) -> Bool {
        if CGPreflightPostEventAccess() {
            return true
        }
        return prompt ? CGRequestPostEventAccess() : false
    }

    func postPasteShortcut(to target: PasteTarget) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandDown.postToPid(target.processIdentifier)
        keyDown.postToPid(target.processIdentifier)
        keyUp.postToPid(target.processIdentifier)
        commandUp.postToPid(target.processIdentifier)
        return true
    }
}

struct PasteboardItemSnapshot: Equatable, Sendable {
    let representations: [String: Data]
}

struct PasteboardSnapshot: Equatable, Sendable {
    let items: [PasteboardItemSnapshot]
}

enum PasteboardSnapshotFailure: Error, Equatable, Sendable {
    case clipboardChanged
    case representationReadFailed(type: String)
}

enum PasteboardMutationFailure: Equatable, Sendable {
    case clearFailed
    case writeFailed
    case verificationFailed
    case representationWriteFailed(type: String)
}

enum PasteboardReplacementResult: Equatable, Sendable {
    case replaced(changeCount: Int)
    case failed(PasteboardMutationFailure, currentChangeCount: Int)
}

enum ClipboardRestorationOutcome: Equatable, Sendable {
    case restored
    case skippedBecauseClipboardChanged
    case failed(PasteboardMutationFailure)
}

@MainActor
protocol PasteboardServing: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> Result<PasteboardSnapshot, PasteboardSnapshotFailure>
    func replaceContents(with text: String) -> PasteboardReplacementResult
    func restore(_ snapshot: PasteboardSnapshot, ifUnchangedSince changeCount: Int) -> ClipboardRestorationOutcome
}

@MainActor
final class SystemPasteboardService: PasteboardServing {
    private let pasteboard: NSPasteboard
    private let representationWriter: (NSPasteboardItem, Data, NSPasteboard.PasteboardType) -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        representationWriter: @escaping (NSPasteboardItem, Data, NSPasteboard.PasteboardType) -> Bool = { $0.setData($1, forType: $2) }
    ) {
        self.pasteboard = pasteboard
        self.representationWriter = representationWriter
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> Result<PasteboardSnapshot, PasteboardSnapshotFailure> {
        let initialChangeCount = pasteboard.changeCount
        let items = pasteboard.pasteboardItems ?? []
        var snapshots: [PasteboardItemSnapshot] = []
        for item in items {
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return .failure(.representationReadFailed(type: type.rawValue))
                }
                representations[type.rawValue] = data
            }
            snapshots.append(PasteboardItemSnapshot(representations: representations))
        }
        guard pasteboard.changeCount == initialChangeCount else {
            return .failure(.clipboardChanged)
        }
        return .success(PasteboardSnapshot(items: snapshots))
    }

    func replaceContents(with text: String) -> PasteboardReplacementResult {
        let originalCount = pasteboard.changeCount
        let clearedCount = pasteboard.clearContents()
        guard clearedCount != originalCount else {
            return .failed(.clearFailed, currentChangeCount: pasteboard.changeCount)
        }
        guard pasteboard.setString(text, forType: .string) else {
            return .failed(.writeFailed, currentChangeCount: pasteboard.changeCount)
        }
        guard pasteboard.string(forType: .string) == text else {
            return .failed(.verificationFailed, currentChangeCount: pasteboard.changeCount)
        }
        return .replaced(changeCount: pasteboard.changeCount)
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifUnchangedSince changeCount: Int
    ) -> ClipboardRestorationOutcome {
        guard pasteboard.changeCount == changeCount else {
            return .skippedBecauseClipboardChanged
        }
        var items: [NSPasteboardItem] = []
        for snapshotItem in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in snapshotItem.representations {
                let type = NSPasteboard.PasteboardType(rawType)
                guard representationWriter(item, data, type) else {
                    return .failed(.representationWriteFailed(type: rawType))
                }
            }
            items.append(item)
        }
        let beforeClear = pasteboard.changeCount
        guard beforeClear == changeCount else { return .skippedBecauseClipboardChanged }
        let clearedCount = pasteboard.clearContents()
        guard clearedCount != beforeClear else {
            return .failed(.clearFailed)
        }
        guard !items.isEmpty else {
            return .restored
        }
        guard pasteboard.writeObjects(items) else {
            return .failed(.writeFailed)
        }
        return .restored
    }
}

@MainActor
protocol DeliverySleeping: AnyObject {
    func sleep(for duration: TimeInterval) async -> Bool
}

@MainActor
final class SystemDeliverySleeper: DeliverySleeping {
    func sleep(for duration: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(max(0, duration)))
            return true
        } catch {
            return false
        }
    }
}

enum ManualPasteReason: Equatable, Sendable {
    case noSessionTarget
    case targetExited
    case targetIdentityChanged
    case targetHasNoWindow
    case targetCouldNotBeVerified
    case eventPermissionDenied
    case activationFailed
    case eventPostFailed
}

enum DeliveryFailure: Equatable, Sendable {
    case pasteboardSnapshotFailed(PasteboardSnapshotFailure)
    case pasteboardWriteFailed(PasteboardMutationFailure, restoration: ClipboardRestorationOutcome)
}

enum DeliveryOutcome: Equatable, Sendable {
    case inserted
    case pasted(restoration: ClipboardRestorationOutcome)
    case copiedForManualPaste(ManualPasteReason)
    case failed(DeliveryFailure)
    case cancelled(restoration: ClipboardRestorationOutcome?)
}

@MainActor
protocol TextDelivering: AnyObject {
    func captureCurrentTarget(excludingBundleIdentifier: String?) -> PasteTarget?
    func deliver(_ text: String, to target: PasteTarget?) async -> DeliveryOutcome
}

@MainActor
final class TextDeliveryService: TextDelivering {
    private let workspace: any WorkspaceServing
    private let accessibility: any AccessibilityServing
    private let pasteboard: any PasteboardServing
    private let eventPoster: any PasteEventPosting
    private let sleeper: any DeliverySleeping
    private let activationAttempts: Int
    private let activationRetryDelay: TimeInterval
    private let restorationDelay: TimeInterval
    private var clipboardTransactionActive = false
    private struct ClipboardWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var clipboardWaiters: [ClipboardWaiter] = []
    private var pendingClipboardWaiterRegistrations: Set<UUID> = []
    private var cancelledClipboardWaiters: Set<UUID> = []

    init(
        workspace: any WorkspaceServing = SystemWorkspaceService(),
        accessibility: any AccessibilityServing = SystemAccessibilityService(),
        pasteboard: any PasteboardServing = SystemPasteboardService(),
        eventPoster: any PasteEventPosting = SystemPasteEventPoster(),
        sleeper: any DeliverySleeping = SystemDeliverySleeper(),
        activationAttempts: Int = 7,
        activationRetryDelay: TimeInterval = 0.15,
        restorationDelay: TimeInterval = 0.75
    ) {
        self.workspace = workspace
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.eventPoster = eventPoster
        self.sleeper = sleeper
        self.activationAttempts = max(1, activationAttempts)
        self.activationRetryDelay = max(0, activationRetryDelay)
        self.restorationDelay = max(0, restorationDelay)
    }

    func captureCurrentTarget(excludingBundleIdentifier: String?) -> PasteTarget? {
        workspace.currentExternalTarget(excludingBundleIdentifier: excludingBundleIdentifier)
    }

    func deliver(_ text: String, to target: PasteTarget?) async -> DeliveryOutcome {
        guard !Task.isCancelled else {
            return .cancelled(restoration: nil)
        }
        if let target,
           workspace.availability(of: target) == .available,
           accessibility.ensurePermission(prompt: true),
           accessibility.insert(text, into: target) == .inserted {
            return .inserted
        }
        guard await acquireClipboardTransaction() else {
            return .cancelled(restoration: nil)
        }
        defer { releaseClipboardTransaction() }
        guard !Task.isCancelled else {
            return .cancelled(restoration: nil)
        }
        let originalContents: PasteboardSnapshot
        switch pasteboard.snapshot() {
        case let .success(snapshot):
            originalContents = snapshot
        case let .failure(failure):
            return .failed(.pasteboardSnapshotFailed(failure))
        }
        let replacement = pasteboard.replaceContents(with: text)
        let transientChangeCount: Int
        switch replacement {
        case let .replaced(changeCount):
            transientChangeCount = changeCount
        case let .failed(failure, currentChangeCount):
            let restoration = pasteboard.restore(originalContents, ifUnchangedSince: currentChangeCount)
            return .failed(.pasteboardWriteFailed(failure, restoration: restoration))
        }

        if Task.isCancelled {
            return .cancelled(restoration: pasteboard.restore(originalContents, ifUnchangedSince: transientChangeCount))
        }
        guard let target else {
            return .copiedForManualPaste(.noSessionTarget)
        }

        switch workspace.availability(of: target) {
        case .exited:
            return .copiedForManualPaste(.targetExited)
        case .identityChanged:
            return .copiedForManualPaste(.targetIdentityChanged)
        case .available:
            break
        }
        guard accessibility.ensurePermission(prompt: true) else {
            return .copiedForManualPaste(.targetCouldNotBeVerified)
        }
        switch accessibility.windowAvailability(of: target) {
        case .closed:
            return .copiedForManualPaste(.targetHasNoWindow)
        case .unavailable:
            return .copiedForManualPaste(.targetCouldNotBeVerified)
        case .available:
            break
        }

        guard eventPoster.ensurePermission(prompt: true) else {
            return .copiedForManualPaste(.eventPermissionDenied)
        }

        var targetConfirmedFrontmost = false
        for _ in 0..<activationAttempts {
            if Task.isCancelled {
                return .cancelled(restoration: pasteboard.restore(originalContents, ifUnchangedSince: transientChangeCount))
            }

            switch workspace.availability(of: target) {
            case .exited:
                return .copiedForManualPaste(.targetExited)
            case .identityChanged:
                return .copiedForManualPaste(.targetIdentityChanged)
            case .available:
                break
            }

            let activationOutcome = workspace.activate(target)
            switch activationOutcome {
            case .targetExited:
                return .copiedForManualPaste(.targetExited)
            case .identityChanged:
                return .copiedForManualPaste(.targetIdentityChanged)
            case .requested, .rejected:
                break
            }
            guard await sleeper.sleep(for: activationRetryDelay) else {
                return .cancelled(restoration: pasteboard.restore(originalContents, ifUnchangedSince: transientChangeCount))
            }

            if activationOutcome == .requested,
               workspace.frontmostTarget() == target {
                targetConfirmedFrontmost = true
                break
            }
        }

        guard targetConfirmedFrontmost else {
            return .copiedForManualPaste(.activationFailed)
        }

        // Re-check every identity/window condition immediately before posting.
        guard workspace.availability(of: target) == .available,
              workspace.frontmostTarget() == target else {
            return .copiedForManualPaste(.activationFailed)
        }
        switch accessibility.windowAvailability(of: target) {
        case .closed:
            return .copiedForManualPaste(.targetHasNoWindow)
        case .unavailable:
            return .copiedForManualPaste(.targetCouldNotBeVerified)
        case .available:
            break
        }
        guard eventPoster.postPasteShortcut(to: target) else {
            return .copiedForManualPaste(.eventPostFailed)
        }

        guard await sleeper.sleep(for: restorationDelay) else {
            return .cancelled(restoration: pasteboard.restore(originalContents, ifUnchangedSince: transientChangeCount))
        }
        return .pasted(restoration: pasteboard.restore(originalContents, ifUnchangedSince: transientChangeCount))
    }

    private func acquireClipboardTransaction() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        if !clipboardTransactionActive {
            clipboardTransactionActive = true
            return true
        }

        let identifier = UUID()
        pendingClipboardWaiterRegistrations.insert(identifier)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingClipboardWaiterRegistrations.remove(identifier)
                if Task.isCancelled || cancelledClipboardWaiters.remove(identifier) != nil {
                    continuation.resume(returning: false)
                } else {
                    clipboardWaiters.append(
                        ClipboardWaiter(
                            identifier: identifier,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelClipboardWaiter(identifier)
            }
        }
    }

    private func releaseClipboardTransaction() {
        guard !clipboardWaiters.isEmpty else {
            clipboardTransactionActive = false
            return
        }
        let next = clipboardWaiters.removeFirst()
        next.continuation.resume(returning: true)
    }

    private func cancelClipboardWaiter(_ identifier: UUID) {
        if let index = clipboardWaiters.firstIndex(where: { $0.identifier == identifier }) {
            let waiter = clipboardWaiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else if pendingClipboardWaiterRegistrations.contains(identifier) {
            cancelledClipboardWaiters.insert(identifier)
        }
    }
}
