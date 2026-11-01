import AppKit
import ApplicationServices
import Foundation

/// Chromium and Electron apps keep their accessibility tree empty until a
/// trusted client opts in, which hides their text fields from dictation.
enum AccessibilityEnhancements {
    static func enable(for processIdentifier: pid_t) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// Uses selection replacement first so native and rich editors retain their
/// formatting and undo behavior while a live transcript is revised.
@MainActor
final class SystemLiveTextElement: LiveTextElement {
    private let element: AXUIElement
    private let processIdentifier: pid_t
    private let bundleIdentifier: String?

    private init(element: AXUIElement, target: PasteTarget) {
        self.element = element
        self.processIdentifier = target.processIdentifier
        self.bundleIdentifier = target.bundleIdentifier
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    static func focused(for target: PasteTarget) -> (any LiveTextElement)? {
        if let element = focusedElement(), let wrapped = wrap(element, for: target) {
            return wrapped
        }
        // A busy or opted-out app may answer late or not at all; opting in and
        // retrying once recovers fields the first query could not see.
        AccessibilityEnhancements.enable(for: target.processIdentifier)
        guard let element = focusedElement() else { return nil }
        return wrap(element, for: target)
    }

    /// The system-wide focused element is the user's cursor even when a helper
    /// process owns it: browser and Electron fields live in web-content and
    /// renderer processes, not the target app's. Those are accepted while the
    /// target stays frontmost, which keeps the guard against stale targets.
    static func accepts(
        elementProcessIdentifier: pid_t,
        target: PasteTarget,
        frontmostProcessIdentifier: pid_t?
    ) -> Bool {
        elementProcessIdentifier == target.processIdentifier
            || frontmostProcessIdentifier == target.processIdentifier
    }

    private static func wrap(_ element: AXUIElement, for target: PasteTarget) -> (any LiveTextElement)? {
        var elementProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessIdentifier) == .success else { return nil }
        guard accepts(
            elementProcessIdentifier: elementProcessIdentifier,
            target: target,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) else { return nil }
        // Keystrokes must go to the app that owns the window, never a helper.
        return SystemLiveTextElement(element: element, target: target)
    }

    var text: String? {
        attribute(kAXValueAttribute) as? String
    }

    var selection: NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    var isFocused: Bool {
        guard let focused = Self.focusedElement() else { return false }
        return CFEqual(focused, element)
    }

    var canReplaceSelectedText: Bool {
        isSettable(kAXSelectedTextAttribute) && isSettable(kAXSelectedTextRangeAttribute)
    }

    var canReplaceValue: Bool {
        isSettable(kAXValueAttribute)
    }

    var canTypeAtSelection: Bool {
        isSettable(kAXSelectedTextRangeAttribute) && CGPreflightPostEventAccess()
    }

    var requiresKeystrokeDrafts: Bool {
        if Self.forcesKeystrokeDrafts(bundleIdentifier: bundleIdentifier) { return true }
        // Web fields cannot be edited reliably through Accessibility. Safari
        // reports AXSelectedText writes as successful without applying them, and
        // AXValue writes bypass input events, so editors like Draft.js (X) keep
        // text in their model that the page never shows. Keystrokes go through
        // the page's own input handling in every browser and Electron app.
        if Self.isInWebContent(element) { return true }
        // Terminal's read-only text area represents the rendered screen, not an
        // editable buffer. Its writable AX selection only highlights output.
        // Normal editable controls (Find, Settings, etc.) retain AX editing.
        return bundleIdentifier == "com.apple.Terminal"
            && attribute(kAXRoleAttribute) as? String == kAXTextAreaRole
            && !canReplaceSelectedText && !canReplaceValue
    }

    static func forcesKeystrokeDrafts(bundleIdentifier: String?) -> Bool {
        switch bundleIdentifier {
        case "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary":
            true
        default:
            false
        }
    }

    /// Browsers and Electron expose page content beneath an AXWebArea. Native
    /// controls in the same app, such as the address bar, are not inside one.
    static func isInWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<Self.webAreaSearchDepth {
            guard let candidate = current else { return false }
            if Self.attribute(kAXRoleAttribute, of: candidate) as? String == Self.webAreaRole { return true }
            guard let parent = Self.attribute(kAXParentAttribute, of: candidate),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static let webAreaRole = "AXWebArea"
    private static let webAreaSearchDepth = 64

    func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    func setValue(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    func select(_ selection: NSRange) -> Bool {
        var range = CFRange(location: selection.location, length: selection.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func typeAtSelection(_ replacement: String) async -> Bool {
        guard !Task.isCancelled, isFocused,
              let currentText = text, let selection,
              selection.location >= 0, selection.length >= 0,
              selection.location <= (currentText as NSString).length,
              selection.length <= (currentText as NSString).length - selection.location,
              let source = CGEventSource(stateID: .privateState) else { return false }
        let expectedText = (currentText as NSString).replacingCharacters(in: selection, with: replacement)
        // Delete the selected draft when cancelling or revising to empty.
        let deletions = replacement.isEmpty ? 1 : 0
        guard let events = KeystrokeEvents.make(deleting: deletions, inserting: replacement, source: source) else { return false }
        KeystrokeEvents.post(events, to: processIdentifier)
        // Wait off the UI thread's synchronous path for the editor to apply the
        // events. Even a cancelled draft must settle before restoring its range.
        let acknowledgement = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(250))
            while clock.now < deadline {
                if self.text == expectedText { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await acknowledgement.value
        // If an app does not reflect its text in time, the next guarded edit
        // checks ownership again before touching the draft.
        return true
    }

    private func attribute(_ name: String) -> CFTypeRef? {
        Self.attribute(name, of: element)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

/// Synthetic keyboard events that carry text rather than key codes, so the
/// destination's keyboard layout and input method cannot change the result.
enum KeystrokeEvents {
    private static let deleteKeyCode: CGKeyCode = 51

    static func make(deleting deletions: Int, inserting text: String, source: CGEventSource) -> [CGEvent]? {
        var events: [CGEvent] = []
        for _ in 0..<max(0, deletions) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false) else { return nil }
            events.append(contentsOf: [down, keyUp])
        }
        for chunk in unicodeChunks(text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
            chunk.withUnsafeBufferPointer { units in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress!)
                keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress!)
            }
            events.append(contentsOf: [down, keyUp])
        }
        return events
    }

    /// Right Option may still be physically held. Dictated text must arrive
    /// as text, without inheriting modifier keys or triggering shortcuts.
    static func post(_ events: [CGEvent], to processIdentifier: pid_t) {
        for event in events {
            event.flags = []
            event.postToPid(processIdentifier)
        }
    }

    /// Safari applies posted Delete presses after text posted behind them, so a
    /// revision that deletes a tail and retypes it scrambles the draft. Letting
    /// the deletions settle before typing keeps the order. The batch runs in its
    /// own task so cancelling a draft cannot stop it halfway, which would leave
    /// text the editor no longer tracks.
    @MainActor
    static func postDeletionsBeforeText(_ events: [CGEvent], to processIdentifier: pid_t) async {
        let delivery = Task { @MainActor in
            let deletions = events.prefix { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(deleteKeyCode) }
            let insertions = events.dropFirst(deletions.count)
            post(Array(deletions), to: processIdentifier)
            if !deletions.isEmpty, !insertions.isEmpty {
                try? await Task.sleep(for: deletionSettleInterval)
            }
            post(Array(insertions), to: processIdentifier)
        }
        await delivery.value
    }

    /// 20 ms was enough to retype a 120-character draft in Safari; this leaves margin.
    static let deletionSettleInterval: Duration = .milliseconds(50)

    private static func unicodeChunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > 20 {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Types into apps whose text fields do not answer Accessibility queries, such
/// as GPU-rendered terminals. It cannot read the field, so it only edits text it
/// typed itself and only while the captured app stays frontmost.
@MainActor
final class SystemLiveKeystrokeTyper: LiveKeystrokeTyping {
    func canType(into target: PasteTarget) -> Bool {
        CGPreflightPostEventAccess()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    func type(deleting deletions: Int, inserting text: String, into target: PasteTarget) async -> Bool {
        guard !Task.isCancelled, canType(into: target),
              let source = CGEventSource(stateID: .privateState),
              let events = KeystrokeEvents.make(deleting: deletions, inserting: text, source: source) else { return false }
        guard !events.isEmpty else { return true }
        await KeystrokeEvents.postDeletionsBeforeText(events, to: target.processIdentifier)
        // Without a readable value there is no acknowledgement to wait for. A
        // short pause lets the app drain this batch before the next revision.
        try? await Task.sleep(for: .milliseconds(20))
        return true
    }
}
