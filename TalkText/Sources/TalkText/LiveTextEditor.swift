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
    case liveDraftChanged
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
    func updateLiveTranscript(_ text: String, in target: PasteTarget?) async -> Bool
    func finalizeLiveTranscript(_ text: String, in target: PasteTarget?) async -> DeliveryOutcome
    func cancelLiveTranscript()
    func deliver(_ text: String, to target: PasteTarget?) async -> DeliveryOutcome
}

extension TextDelivering {
    func updateLiveTranscript(_ text: String, in target: PasteTarget?) async -> Bool {
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

enum LiveTextCancellationOutcome: Equatable, Sendable {
    case restored
    case noActiveDraft
    case unavailable
}

@MainActor
protocol LiveTextEditing: AnyObject {
    func update(_ text: String, in target: PasteTarget) async -> LiveTextUpdateOutcome
    func finalize(_ text: String, in target: PasteTarget) async -> LiveTextFinalizationOutcome
    @discardableResult func cancel() async -> LiveTextCancellationOutcome
}

@MainActor
protocol LiveTextElement: AnyObject {
    var text: String? { get }
    var selection: NSRange? { get }
    var isFocused: Bool { get }
    var canReplaceSelectedText: Bool { get }
    var canReplaceValue: Bool { get }
    var canTypeAtSelection: Bool { get }
    func setSelectedText(_ text: String) -> Bool
    func setValue(_ text: String) -> Bool
    func select(_ range: NSRange) -> Bool
    func typeAtSelection(_ text: String) async -> Bool
}

extension LiveTextElement {
    func replace(_ range: NSRange, with replacement: String) async -> Bool {
        guard let text,
              range.location >= 0, range.length >= 0,
              range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location else {
            return false
        }
        let updatedValue = (text as NSString).replacingCharacters(in: range, with: replacement)
        if updatedValue == text { return true }
        if canReplaceSelectedText {
            let previousSelection = selection
            if select(range), setSelectedText(replacement) { return true }
            if let previousSelection { _ = select(previousSelection) }
        }
        // A read-only AXValue is common in rich editors. Reading it must not
        // prevent editing through their writable AXSelectedText attribute.
        guard self.text == text else { return false }
        if canReplaceValue, setValue(updatedValue) { return true }
        guard canTypeAtSelection, isFocused, select(range) else { return false }
        return await typeAtSelection(replacement)
    }
}

@MainActor
protocol LiveKeystrokeTyping: AnyObject {
    func canType(into target: PasteTarget) -> Bool
    func type(deleting deletions: Int, inserting text: String, into target: PasteTarget) async -> Bool
}

/// Maintains one guarded replacement range in the text field that owned the
/// cursor when dictation began. Each transcription draft replaces the previous one;
/// it is never appended repeatedly as recognition revises earlier words.
@MainActor
final class SystemLiveTextEditor: LiveTextEditing {
    private struct Session {
        let target: PasteTarget
        let element: any LiveTextElement
        let replacementLocation: Int
        let originalText: String
        var draftUTF16Length: Int
        var expectedValue: String
        /// False while only the cursor has been captured. Until a draft lands,
        /// a field that refuses edits can still hand over to keystroke typing.
        var hasDraft: Bool
    }

    /// Text typed blind into an app whose focused field cannot be read or
    /// edited through Accessibility. Each revision deletes only the characters
    /// that changed since the last draft.
    private struct KeystrokeSession {
        let target: PasteTarget
        var typedText: String
    }

    private var session: Session?
    private var keystrokeSession: KeystrokeSession?
    private var pendingOperation: Task<Void, Never>?
    private let focusedElement: @MainActor (PasteTarget) -> (any LiveTextElement)?
    private let keystrokeTyper: (any LiveKeystrokeTyping)?

    init(
        focusedElement: @escaping @MainActor (PasteTarget) -> (any LiveTextElement)? = SystemLiveTextElement.focused,
        keystrokeTyper: (any LiveKeystrokeTyping)? = SystemLiveKeystrokeTyper()
    ) {
        self.focusedElement = focusedElement
        self.keystrokeTyper = keystrokeTyper
    }

    func update(_ text: String, in target: PasteTarget) async -> LiveTextUpdateOutcome {
        await serially { await self.updateDraft(text, in: target) }
    }

    private func updateDraft(_ text: String, in target: PasteTarget) async -> LiveTextUpdateOutcome {
        guard !Task.isCancelled else { return .unavailable }
        if keystrokeSession != nil {
            guard await reviseKeystrokeDraft(to: text, in: target) else {
                liveTextLogger.debug("Keystroke draft revision failed")
                return .unavailable
            }
            return .updated
        }
        if var session {
            guard session.target == target, session.element.isFocused else {
                liveTextLogger.debug("Live draft skipped; focus left the dictation field")
                return .unavailable
            }
            guard let updatedValue = replacingDraft(in: session, with: text) else {
                liveTextLogger.debug("Live draft skipped; field changed outside dictation")
                return .unavailable
            }
            guard await session.element.replace(replacementRange(in: session), with: text) else {
                guard !session.hasDraft else {
                    liveTextLogger.debug("Live draft replacement was rejected by the field")
                    return .unavailable
                }
                liveTextLogger.debug("Focused field rejected edits; using keystroke drafts")
                self.session = nil
                return await beginKeystrokeDraft(text, in: target)
            }
            _ = session.element.select(NSRange(location: session.replacementLocation + (text as NSString).length, length: 0))
            session.draftUTF16Length = (text as NSString).length
            session.expectedValue = updatedValue
            session.hasDraft = true
            self.session = session
            return .updated
        }

        // Editors such as Sublime Text expose a focused element without its
        // value, and GPU terminals expose none at all. Both still accept typed
        // text at the cursor.
        guard let element = focusedElement(target), let currentValue = element.text else {
            liveTextLogger.debug("No readable focused field; using keystroke drafts")
            return await beginKeystrokeDraft(text, in: target)
        }
        // A readable value with no usable selection has an unknown cursor, so
        // typing there could land anywhere in the user's text.
        guard let replacementRange = element.selection,
              replacementRange.location >= 0, replacementRange.length >= 0,
              replacementRange.location <= (currentValue as NSString).length,
              replacementRange.length <= (currentValue as NSString).length - replacementRange.location else {
            liveTextLogger.debug("Focused field has no usable selection")
            return .unavailable
        }
        let currentNSString = currentValue as NSString
        let originalText = currentNSString.substring(with: replacementRange)
        // Prime the original selection without deleting it during microphone
        // startup. The first actual draft performs the guarded replacement.
        if text.isEmpty {
            session = Session(target: target, element: element, replacementLocation: replacementRange.location,
                              originalText: originalText, draftUTF16Length: replacementRange.length,
                              expectedValue: currentValue, hasDraft: false)
            return .updated
        }
        let updatedValue = currentNSString.replacingCharacters(in: replacementRange, with: text)
        guard await element.replace(replacementRange, with: text) else {
            liveTextLogger.debug("Focused field rejected edits; using keystroke drafts")
            return await beginKeystrokeDraft(text, in: target)
        }
        _ = element.select(NSRange(location: replacementRange.location + (text as NSString).length, length: 0))

        session = Session(
            target: target,
            element: element,
            replacementLocation: replacementRange.location,
            originalText: originalText,
            draftUTF16Length: (text as NSString).length,
            expectedValue: updatedValue,
            hasDraft: true
        )
        return .updated
    }

    func finalize(_ text: String, in target: PasteTarget) async -> LiveTextFinalizationOutcome {
        await serially { await self.finalizeDraft(text, in: target) }
    }

    private func finalizeDraft(_ text: String, in target: PasteTarget) async -> LiveTextFinalizationOutcome {
        guard !Task.isCancelled else { return .unavailable }
        if keystrokeSession != nil {
            guard await reviseKeystrokeDraft(to: text, in: target) else { return .unavailable }
            keystrokeSession = nil
            return .finalized
        }
        guard let session else {
            return .noActiveDraft
        }
        guard session.target == target,
              replacingDraft(in: session, with: text) != nil,
              await session.element.replace(replacementRange(in: session), with: text) else {
            return .unavailable
        }
        self.session = nil
        _ = session.element.select(NSRange(location: session.replacementLocation + (text as NSString).length, length: 0))
        return .finalized
    }

    @discardableResult
    func cancel() async -> LiveTextCancellationOutcome {
        await serially { await self.restoreOriginalText() }
    }

    private func restoreOriginalText() async -> LiveTextCancellationOutcome {
        if let keystrokeSession {
            self.keystrokeSession = nil
            guard let keystrokeTyper,
                  await keystrokeTyper.type(deleting: keystrokeSession.typedText.count, inserting: "", into: keystrokeSession.target) else {
                return .unavailable
            }
            return .restored
        }
        guard let session else {
            return .noActiveDraft
        }
        self.session = nil
        guard replacingDraft(in: session, with: session.originalText) != nil,
              await session.element.replace(replacementRange(in: session), with: session.originalText) else {
            return .unavailable
        }
        _ = session.element.select(NSRange(location: session.replacementLocation, length: (session.originalText as NSString).length))
        return .restored
    }

    private func beginKeystrokeDraft(_ text: String, in target: PasteTarget) async -> LiveTextUpdateOutcome {
        let text = Self.blindKeystrokeText(text)
        guard let keystrokeTyper, keystrokeTyper.canType(into: target),
              await keystrokeTyper.type(deleting: 0, inserting: text, into: target) else {
            liveTextLogger.debug("Keystroke draft could not start")
            return .unavailable
        }
        keystrokeSession = KeystrokeSession(target: target, typedText: text)
        return .updated
    }

    /// Keeps the shared prefix in place so a revision near the end of a long
    /// draft costs a few keystrokes rather than retyping everything.
    private func reviseKeystrokeDraft(to text: String, in target: PasteTarget) async -> Bool {
        let text = Self.blindKeystrokeText(text)
        guard var keystrokeSession, let keystrokeTyper, keystrokeSession.target == target else { return false }
        let typed = Array(keystrokeSession.typedText)
        let revised = Array(text)
        var shared = 0
        while shared < typed.count, shared < revised.count, typed[shared] == revised[shared] {
            shared += 1
        }
        guard await keystrokeTyper.type(
            deleting: typed.count - shared,
            inserting: String(revised[shared...]),
            into: target
        ) else {
            return false
        }
        keystrokeSession.typedText = text
        self.keystrokeSession = keystrokeSession
        return true
    }

    /// A blind field is often a terminal, where a typed line break or tab is
    /// Return or completion rather than text. Flatten them so dictation can
    /// never submit or complete a command before the user does.
    static func blindKeystrokeText(_ text: String) -> String {
        String(text.map { character in
            character.unicodeScalars.contains { scalar in
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator: true
                default: false
                }
            } ? " " : character
        })
    }

    private func replacingDraft(in session: Session, with replacement: String) -> String? {
        guard let currentValue = session.element.text,
              currentValue == session.expectedValue else {
            return nil
        }
        let currentNSString = currentValue as NSString
        let replacementRange = replacementRange(in: session)
        guard NSMaxRange(replacementRange) <= currentNSString.length else {
            return nil
        }
        return currentNSString.replacingCharacters(in: replacementRange, with: replacement)
    }

    private func replacementRange(in session: Session) -> NSRange {
        NSRange(location: session.replacementLocation, length: session.draftUTF16Length)
    }

    /// Keystrokes are delivered asynchronously by the destination app. A final
    /// write or cancellation must wait for the current draft before replacing it.
    private func serially<Result: Sendable>(
        _ operation: @escaping @MainActor () async -> Result
    ) async -> Result {
        let previous = pendingOperation
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        pendingOperation = Task { _ = await task.value }
        return await withTaskCancellationHandler {
            if Task.isCancelled { task.cancel() }
            return await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
