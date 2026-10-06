import AppKit
import ApplicationServices
import Foundation

/// Uses selection replacement first so native and rich editors retain their
/// formatting and undo behavior while a live transcript is revised.
@MainActor
final class SystemLiveTextElement: LiveTextElement {
    private let element: AXUIElement
    private let processIdentifier: pid_t

    private init(element: AXUIElement, processIdentifier: pid_t) {
        self.element = element
        self.processIdentifier = processIdentifier
        AXUIElementSetMessagingTimeout(element, 0.15)
    }

    static func focused(for target: PasteTarget) -> (any LiveTextElement)? {
        guard let element = focusedElement() else { return nil }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == target.processIdentifier else { return nil }
        return SystemLiveTextElement(element: element, processIdentifier: processIdentifier)
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
        AXUIElementSetMessagingTimeout(system, 0.15)
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
        KeystrokeEvents.post(events, to: target.processIdentifier)
        // Without a readable value there is no acknowledgement to wait for. A
        // short pause lets the app drain this batch before the next revision.
        try? await Task.sleep(for: .milliseconds(20))
        return true
    }
}
