import ApplicationServices
import Foundation

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
    func updateLiveTranscript(_ text: String, in target: PasteTarget?) -> Bool
    func finalizeLiveTranscript(_ text: String, in target: PasteTarget?) async -> DeliveryOutcome
    func cancelLiveTranscript()
    func deliver(_ text: String, to target: PasteTarget?) async -> DeliveryOutcome
}

extension TextDelivering {
    func updateLiveTranscript(_ text: String, in target: PasteTarget?) -> Bool {
        false
    }

    func finalizeLiveTranscript(_ text: String, in target: PasteTarget?) async -> DeliveryOutcome {
        await deliver(text, to: target)
    }

    func cancelLiveTranscript() {}
}

enum LiveTextUpdateOutcome: Equatable, Sendable {
    case updated
    case unavailable
}

enum LiveTextFinalizationOutcome: Equatable, Sendable {
    case finalized
    case noActiveDraft
    case unavailable
}

@MainActor
protocol LiveTextEditing: AnyObject {
    func update(_ text: String, in target: PasteTarget) -> LiveTextUpdateOutcome
    func finalize(_ text: String, in target: PasteTarget) -> LiveTextFinalizationOutcome
    func cancel()
}

/// Maintains one guarded replacement range in the text field that owned the
/// cursor when dictation began. Each Whisper draft replaces the previous one;
/// it is never appended repeatedly as recognition revises earlier words.
@MainActor
final class SystemLiveTextEditor: LiveTextEditing {
    private struct Session {
        let target: PasteTarget
        let element: AXUIElement
        let replacementLocation: Int
        let originalText: String
        var draftUTF16Length: Int
        var expectedValue: String
    }

    private var session: Session?

    func update(_ text: String, in target: PasteTarget) -> LiveTextUpdateOutcome {
        if var session {
            guard session.target == target,
                  let updatedValue = replacingDraft(in: session, with: text),
                  setValue(updatedValue, on: session.element) else {
                self.session = nil
                return .unavailable
            }
            _ = setSelection(
                location: session.replacementLocation + (text as NSString).length,
                length: 0,
                on: session.element
            )
            session.draftUTF16Length = (text as NSString).length
            session.expectedValue = updatedValue
            self.session = session
            return .updated
        }

        guard let element = focusedElement(for: target),
              let currentValue = value(of: element) else {
            return .unavailable
        }
        let currentNSString = currentValue as NSString
        var selectedRange = selectedTextRange(of: element)
            ?? CFRange(location: currentNSString.length, length: 0)
        selectedRange.location = max(0, min(selectedRange.location, currentNSString.length))
        selectedRange.length = max(
            0,
            min(selectedRange.length, currentNSString.length - selectedRange.location)
        )
        let replacementRange = NSRange(location: selectedRange.location, length: selectedRange.length)
        let originalText = currentNSString.substring(with: replacementRange)
        let updatedValue = currentNSString.replacingCharacters(in: replacementRange, with: text)
        guard setValue(updatedValue, on: element) else {
            return .unavailable
        }
        _ = setSelection(
            location: replacementRange.location + (text as NSString).length,
            length: 0,
            on: element
        )

        session = Session(
            target: target,
            element: element,
            replacementLocation: replacementRange.location,
            originalText: originalText,
            draftUTF16Length: (text as NSString).length,
            expectedValue: updatedValue
        )
        return .updated
    }

    func finalize(_ text: String, in target: PasteTarget) -> LiveTextFinalizationOutcome {
        guard let session else {
            return .noActiveDraft
        }
        self.session = nil
        guard session.target == target,
              let updatedValue = replacingDraft(in: session, with: text),
              setValue(updatedValue, on: session.element) else {
            return .unavailable
        }
        _ = setSelection(
            location: session.replacementLocation + (text as NSString).length,
            length: 0,
            on: session.element
        )
        return .finalized
    }

    func cancel() {
        guard let session else {
            return
        }
        self.session = nil
        guard let restoredValue = replacingDraft(in: session, with: session.originalText),
              setValue(restoredValue, on: session.element) else {
            return
        }
        _ = setSelection(
            location: session.replacementLocation,
            length: (session.originalText as NSString).length,
            on: session.element
        )
    }

    private func replacingDraft(in session: Session, with replacement: String) -> String? {
        guard let currentValue = value(of: session.element),
              currentValue == session.expectedValue else {
            return nil
        }
        let currentNSString = currentValue as NSString
        let replacementRange = NSRange(
            location: session.replacementLocation,
            length: session.draftUTF16Length
        )
        guard NSMaxRange(replacementRange) <= currentNSString.length else {
            return nil
        }
        return currentNSString.replacingCharacters(in: replacementRange, with: replacement)
    }

    private func focusedElement(for target: PasteTarget) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
            let focusedElementValue else {
            return nil
        }
        let element = unsafeDowncast(focusedElementValue, to: AXUIElement.self)
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == target.processIdentifier else {
            return nil
        }
        return element
    }

    private func value(of element: AXUIElement) -> String? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success,
            settable.boolValue else {
            return nil
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }
        return (valueRef as? String) ?? ""
    }

    private func setValue(_ value: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
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

    private func setSelection(location: Int, length: Int, on element: AXUIElement) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }
}
