import Foundation
import XCTest
@testable import TalkText

@MainActor
final class LiveTextEditorTests: XCTestCase {
    func testReadOnlyAccessibilityFieldReceivesLiveTypingAtCapturedSelection() async {
        let element = LiveTextElementFake(text: "Before old after", selection: NSRange(location: 7, length: 3))
        element.canReplaceSelectedText = false
        element.canTypeAtSelection = true
        let editor = SystemLiveTextEditor { _ in element }

        let draft = await editor.update("hello 🌎", in: makeTarget())
        let final = await editor.finalize("Hello world.", in: makeTarget())

        XCTAssertEqual(draft, .updated)
        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(element.text, "Before Hello world. after")
        XCTAssertEqual(element.typedTexts, ["hello 🌎", "Hello world."])
        XCTAssertEqual(element.valueWrites, 0)
        XCTAssertEqual(element.selectedTextWrites, 0)
    }

    func testCancellationWaitsForPendingTypedDraftThenRestoresSelection() async {
        let element = LiveTextElementFake(text: "A word", selection: NSRange(location: 2, length: 4))
        element.canReplaceSelectedText = false
        element.canTypeAtSelection = true
        element.typingDelay = .milliseconds(50)
        let editor = SystemLiveTextEditor { _ in element }
        let target = makeTarget()
        let update = Task { await editor.update("draft", in: target) }
        await waitForTyping(in: element)

        update.cancel()
        await editor.cancel()
        _ = await update.value

        XCTAssertEqual(element.text, "A word")
        XCTAssertEqual(element.typedTexts, ["draft", "word"])
        XCTAssertEqual(element.selection, NSRange(location: 2, length: 4))
    }

    func testFinalizationWaitsForPendingTypedDraftAndReplacesItOnce() async {
        let element = LiveTextElementFake(text: "Before after", selection: NSRange(location: 7, length: 0))
        element.canReplaceSelectedText = false
        element.canTypeAtSelection = true
        element.typingDelay = .milliseconds(50)
        let editor = SystemLiveTextEditor { _ in element }
        let target = makeTarget()
        let update = Task { await editor.update("draft ", in: target) }
        await waitForTyping(in: element)

        let final = await editor.finalize("final ", in: target)
        _ = await update.value

        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(element.text, "Before final after")
        XCTAssertEqual(element.typedTexts, ["draft ", "final "])
    }

    func testLiveRevisionsUseSelectionWhenWholeValueIsReadOnly() async {
        let element = LiveTextElementFake(text: "Before old after", selection: NSRange(location: 7, length: 3))
        let editor = SystemLiveTextEditor { _ in element }
        let target = makeTarget()

        let outcome1 = await editor.update("hello", in: target)
        XCTAssertEqual(outcome1, .updated)
        XCTAssertEqual(element.text, "Before hello after")
        let outcome2 = await editor.update("hello 🌎", in: target)
        XCTAssertEqual(outcome2, .updated)
        XCTAssertEqual(element.text, "Before hello 🌎 after")
        let outcome3 = await editor.finalize("Hello world.", in: target)
        XCTAssertEqual(outcome3, .finalized)

        XCTAssertEqual(element.text, "Before Hello world. after")
        XCTAssertEqual(element.selection, NSRange(location: 19, length: 0))
        XCTAssertEqual(element.valueWrites, 0, "A read-only whole-field value must not block cursor insertion")
        XCTAssertEqual(element.selectedTextWrites, 3)
    }

    func testPrimingPreservesOriginalTextAndSelectionUntilSpeechArrives() async {
        let element = LiveTextElementFake(text: "A selected word", selection: NSRange(location: 2, length: 8))
        let editor = SystemLiveTextEditor { _ in element }

        let outcome4 = await editor.update("", in: makeTarget())
        XCTAssertEqual(outcome4, .updated)
        XCTAssertEqual(element.text, "A selected word")
        XCTAssertEqual(element.selection, NSRange(location: 2, length: 8))
        XCTAssertEqual(element.selectedTextWrites, 0)
        await editor.cancel()
        XCTAssertEqual(element.selectedTextWrites, 0)
    }

    func testCancellationRestoresUnicodeSelectionAndSurroundingText() async {
        let element = LiveTextElementFake(text: "🌎 old tail", selection: NSRange(location: 3, length: 3))
        let editor = SystemLiveTextEditor { _ in element }

        let outcome5 = await editor.update("new 🦊 words", in: makeTarget())
        XCTAssertEqual(outcome5, .updated)
        await editor.cancel()

        XCTAssertEqual(element.text, "🌎 old tail")
        XCTAssertEqual(element.selection, NSRange(location: 3, length: 3))
    }

    func testFailedDraftRevisionRetainsOriginalForCancellation() async {
        let element = LiveTextElementFake(text: "start old end", selection: NSRange(location: 6, length: 3))
        let editor = SystemLiveTextEditor { _ in element }
        let outcome6 = await editor.update("draft", in: makeTarget())
        XCTAssertEqual(outcome6, .updated)
        element.rejectedWrites = 1

        let outcome7 = await editor.update("revised draft", in: makeTarget())
        XCTAssertEqual(outcome7, .unavailable)
        XCTAssertEqual(element.text, "start draft end")
        await editor.cancel()
        XCTAssertEqual(element.text, "start old end")
    }

    func testFailedFinalizationCanRemoveDraftBeforeFallbackPaste() async {
        let element = LiveTextElementFake(text: "start end", selection: NSRange(location: 6, length: 0))
        let editor = SystemLiveTextEditor { _ in element }
        let outcome8 = await editor.update("draft ", in: makeTarget())
        XCTAssertEqual(outcome8, .updated)
        element.rejectedWrites = 1

        let outcome9 = await editor.finalize("final ", in: makeTarget())
        XCTAssertEqual(outcome9, .unavailable)
        await editor.cancel()
        XCTAssertEqual(element.text, "start end", "A failed final write must not leave a duplicate draft before paste")
    }

    func testUserEditsArePreservedAndDoNotStartAnotherDraft() async {
        let element = LiveTextElementFake(text: "", selection: NSRange(location: 0, length: 0))
        var captureCount = 0
        let editor = SystemLiveTextEditor { _ in captureCount += 1; return element }
        let outcome10 = await editor.update("draft", in: makeTarget())
        XCTAssertEqual(outcome10, .updated)
        element.text = "draft plus my edit"

        let outcome11 = await editor.update("new words", in: makeTarget())
        XCTAssertEqual(outcome11, .unavailable)
        let outcome12 = await editor.update("more words", in: makeTarget())
        XCTAssertEqual(outcome12, .unavailable)
        await editor.cancel()

        XCTAssertEqual(element.text, "draft plus my edit")
        XCTAssertEqual(captureCount, 1)
    }

    func testSwitchingFocusPausesDraftsAndResumesAtOriginalField() async {
        let element = LiveTextElementFake(text: "", selection: NSRange(location: 0, length: 0))
        let editor = SystemLiveTextEditor { _ in element }
        let outcome13 = await editor.update("one", in: makeTarget())
        XCTAssertEqual(outcome13, .updated)
        element.isFocused = false
        let outcome14 = await editor.update("one two", in: makeTarget())
        XCTAssertEqual(outcome14, .unavailable)
        XCTAssertEqual(element.text, "one")
        element.isFocused = true
        let outcome15 = await editor.update("one two", in: makeTarget())
        XCTAssertEqual(outcome15, .updated)
        XCTAssertEqual(element.text, "one two")
    }

    func testDifferentTargetCannotReplaceCapturedDraft() async {
        let element = LiveTextElementFake(text: "", selection: NSRange(location: 0, length: 0))
        let editor = SystemLiveTextEditor { _ in element }
        let outcome16 = await editor.update("draft", in: makeTarget())
        XCTAssertEqual(outcome16, .updated)
        let outcome17 = await editor.update("wrong", in: makeTarget(pid: 99))
        XCTAssertEqual(outcome17, .unavailable)
        XCTAssertEqual(element.text, "draft")
        let outcome18 = await editor.finalize("final", in: makeTarget())
        XCTAssertEqual(outcome18, .finalized)
        XCTAssertEqual(element.text, "final")
    }

    func testUnavailableOrInvalidSelectionDoesNotAppendAtEnd() async {
        for range in [nil, NSRange(location: NSNotFound, length: 0), NSRange(location: 3, length: 99)] {
            let element = LiveTextElementFake(text: "Keep this", selection: range)
            let editor = SystemLiveTextEditor { _ in element }
            let outcome19 = await editor.update("wrong place", in: makeTarget())
            XCTAssertEqual(outcome19, .unavailable)
            XCTAssertEqual(element.text, "Keep this")
            XCTAssertEqual(element.selectedTextWrites, 0)
        }
    }

    func testWritableWholeValueStillWorksWithoutSelectedTextSupport() async {
        let element = LiveTextElementFake(text: "Before after", selection: NSRange(location: 7, length: 0))
        element.canReplaceSelectedText = false
        element.canReplaceValue = true
        let editor = SystemLiveTextEditor { _ in element }

        let outcome20 = await editor.update("hello ", in: makeTarget())
        XCTAssertEqual(outcome20, .updated)
        XCTAssertEqual(element.text, "Before hello after")
        XCTAssertEqual(element.valueWrites, 1)
        XCTAssertEqual(element.selectedTextWrites, 0)
    }

    func testRejectedSelectionWriteFallsBackToWritableValue() async {
        let element = LiveTextElementFake(text: "A word", selection: NSRange(location: 2, length: 4))
        element.canReplaceValue = true
        element.rejectedWrites = 1
        let editor = SystemLiveTextEditor { _ in element }

        let outcome21 = await editor.update("replacement", in: makeTarget())
        XCTAssertEqual(outcome21, .updated)
        XCTAssertEqual(element.text, "A replacement")
        XCTAssertEqual(element.valueWrites, 1)
    }

    func testIdenticalFinalTextDoesNotCreateAnotherUndoEntry() async {
        let element = LiveTextElementFake(text: "", selection: NSRange(location: 0, length: 0))
        let editor = SystemLiveTextEditor { _ in element }
        let outcome22 = await editor.update("final text", in: makeTarget())
        XCTAssertEqual(outcome22, .updated)
        let outcome23 = await editor.finalize("final text", in: makeTarget())
        XCTAssertEqual(outcome23, .finalized)
        XCTAssertEqual(element.selectedTextWrites, 1)
        let outcome24 = await editor.finalize("final text", in: makeTarget())
        XCTAssertEqual(outcome24, .noActiveDraft)
    }

    func testUnreadableFieldReceivesLiveDraftsAsMinimalKeystrokeRevisions() async {
        let typer = LiveKeystrokeTyperFake()
        let editor = SystemLiveTextEditor(focusedElement: { _ in nil }, keystrokeTyper: typer)
        let target = makeTarget()

        let primed = await editor.update("", in: target)
        let first = await editor.update("hello word", in: target)
        let revised = await editor.update("hello world 🌎", in: target)
        let final = await editor.finalize("Hello world.", in: target)

        XCTAssertEqual(primed, .updated)
        XCTAssertEqual(first, .updated)
        XCTAssertEqual(revised, .updated)
        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(typer.text, "Hello world.")
        XCTAssertEqual(typer.operations.map(\.deletions), [0, 0, 1, 13])
        XCTAssertEqual(typer.operations.last?.insertion, "Hello world.")
        XCTAssertEqual(typer.operations[2].insertion, "ld 🌎", "Only the changed tail is retyped")
        let afterFinal = await editor.cancel()
        XCTAssertEqual(afterFinal, .noActiveDraft)
    }

    func testCancelledKeystrokeDraftDeletesOnlyWhatWasTyped() async {
        let typer = LiveKeystrokeTyperFake(text: "keep ")
        let editor = SystemLiveTextEditor(focusedElement: { _ in nil }, keystrokeTyper: typer)
        let outcome = await editor.update("draft 🌎", in: makeTarget())
        XCTAssertEqual(outcome, .updated)

        let cancelled = await editor.cancel()

        XCTAssertEqual(cancelled, .restored)
        XCTAssertEqual(typer.text, "keep ")
    }

    func testKeystrokeDraftPausesWhileAnotherAppIsFrontmost() async {
        let typer = LiveKeystrokeTyperFake()
        let editor = SystemLiveTextEditor(focusedElement: { _ in nil }, keystrokeTyper: typer)
        let target = makeTarget()
        let started = await editor.update("one", in: target)
        XCTAssertEqual(started, .updated)

        typer.isFrontmost = false
        let paused = await editor.update("one two", in: target)
        let otherTarget = await editor.update("wrong", in: makeTarget(pid: 99))
        let failedFinal = await editor.finalize("one two.", in: target)
        XCTAssertEqual(paused, .unavailable)
        XCTAssertEqual(otherTarget, .unavailable)
        XCTAssertEqual(failedFinal, .unavailable)
        XCTAssertEqual(typer.text, "one")

        typer.isFrontmost = true
        let final = await editor.finalize("one two.", in: target)
        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(typer.text, "one two.")
    }

    func testBlindKeystrokeDraftsCannotSubmitOrCompleteATerminalCommand() async {
        let typer = LiveKeystrokeTyperFake()
        let editor = SystemLiveTextEditor(focusedElement: { _ in nil }, keystrokeTyper: typer)
        let target = makeTarget()

        let first = await editor.update("git push\nrm\t-rf", in: target)
        let final = await editor.finalize("git push\r\nrm\u{2028}-rf 👨‍👩‍👧", in: target)

        XCTAssertEqual(first, .updated)
        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(typer.text, "git push rm -rf 👨‍👩‍👧")
        XCTAssertEqual(typer.operations.last?.deletions, 0, "Flattened revisions still diff against what was typed")
        XCTAssertFalse(typer.operations.contains { $0.insertion.contains { $0.isNewline || $0 == "\t" } })
    }

    func testReadableFieldNeverFallsBackToBlindKeystrokes() async {
        let element = LiveTextElementFake(text: "Keep this", selection: nil)
        let typer = LiveKeystrokeTyperFake()
        let editor = SystemLiveTextEditor(focusedElement: { _ in element }, keystrokeTyper: typer)

        let outcome = await editor.update("wrong place", in: makeTarget())

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(typer.operations.isEmpty)
    }

    func testFieldWithoutReadableValueReceivesKeystrokeDrafts() async {
        let element = LiveTextElementFake(text: "", selection: NSRange(location: 0, length: 0))
        element.text = nil
        let typer = LiveKeystrokeTyperFake()
        let editor = SystemLiveTextEditor(focusedElement: { _ in element }, keystrokeTyper: typer)
        let target = makeTarget()

        let primed = await editor.update("", in: target)
        let draft = await editor.update("one", in: target)
        let final = await editor.finalize("one two.", in: target)

        XCTAssertEqual([primed, draft], [.updated, .updated])
        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(typer.text, "one two.")
        XCTAssertEqual(element.selectedTextWrites, 0)
    }

    func testFieldThatRejectsTheFirstDraftHandsOverToKeystrokes() async {
        let element = LiveTextElementFake(text: "Hi ", selection: NSRange(location: 3, length: 0))
        element.canReplaceSelectedText = false
        let typer = LiveKeystrokeTyperFake(text: "Hi ")
        let editor = SystemLiveTextEditor(focusedElement: { _ in element }, keystrokeTyper: typer)
        let target = makeTarget()

        let primed = await editor.update("", in: target)
        let draft = await editor.update("there", in: target)
        let final = await editor.finalize("there.", in: target)

        XCTAssertEqual([primed, draft], [.updated, .updated])
        XCTAssertEqual(final, .finalized)
        XCTAssertEqual(typer.text, "Hi there.")
        XCTAssertEqual(element.text, "Hi ", "The rejected Accessibility write must not have changed the field")
    }

    func testFieldThatRejectsALaterRevisionKeepsItsDraftForCancellation() async {
        let element = LiveTextElementFake(text: "", selection: NSRange(location: 0, length: 0))
        let typer = LiveKeystrokeTyperFake()
        let editor = SystemLiveTextEditor(focusedElement: { _ in element }, keystrokeTyper: typer)
        _ = await editor.update("", in: makeTarget())
        let draft = await editor.update("draft", in: makeTarget())
        element.rejectedWrites = 1

        let revision = await editor.update("draft two", in: makeTarget())

        XCTAssertEqual([draft, revision], [.updated, .unavailable])
        XCTAssertTrue(typer.operations.isEmpty, "Typing after an Accessibility draft would duplicate it")
        await editor.cancel()
        XCTAssertEqual(element.text, "")
    }

    private func makeTarget(pid: pid_t = 42) -> PasteTarget {
        PasteTarget(processIdentifier: pid, bundleIdentifier: "test.editor", launchDate: Date(timeIntervalSince1970: 0), bundleURL: nil)!
    }

    private func waitForTyping(in element: LiveTextElementFake) async {
        for _ in 0..<1000 {
            if element.typingStarted { return }
            await Task.yield()
        }
        XCTFail("Expected live typing to begin")
    }
}

@MainActor
private final class LiveTextElementFake: LiveTextElement {
    var text: String?
    var selection: NSRange?
    var isFocused = true
    var canReplaceSelectedText = true
    var canReplaceValue = false
    var canTypeAtSelection = false
    var typedTexts: [String] = []
    var typingDelay: Duration = .zero
    private(set) var typingStarted = false
    var rejectedWrites = 0
    private(set) var selectedTextWrites = 0
    private(set) var valueWrites = 0

    init(text: String, selection: NSRange?) {
        self.text = text
        self.selection = selection
    }

    func setSelectedText(_ replacement: String) -> Bool {
        selectedTextWrites += 1
        guard canReplaceSelectedText, acceptsWrite(), let text, let selection else { return false }
        self.text = (text as NSString).replacingCharacters(in: selection, with: replacement)
        return true
    }

    func setValue(_ replacement: String) -> Bool {
        valueWrites += 1
        guard canReplaceValue, acceptsWrite() else { return false }
        text = replacement
        return true
    }

    func select(_ selection: NSRange) -> Bool {
        self.selection = selection
        return true
    }

    func typeAtSelection(_ replacement: String) async -> Bool {
        guard canTypeAtSelection, let text, let selection else { return false }
        typingStarted = true
        let insertion = Task { @MainActor in
            if self.typingDelay != .zero { try? await Task.sleep(for: self.typingDelay) }
            self.text = (text as NSString).replacingCharacters(in: selection, with: replacement)
            self.typedTexts.append(replacement)
        }
        await insertion.value
        return true
    }

    private func acceptsWrite() -> Bool {
        if rejectedWrites > 0 { rejectedWrites -= 1; return false }
        return true
    }
}

@MainActor
private final class LiveKeystrokeTyperFake: LiveKeystrokeTyping {
    var text: String
    var isFrontmost = true
    private(set) var operations: [(deletions: Int, insertion: String)] = []

    init(text: String = "") {
        self.text = text
    }

    func canType(into target: PasteTarget) -> Bool {
        isFrontmost && target.processIdentifier == 42
    }

    func type(deleting deletions: Int, inserting insertion: String, into target: PasteTarget) async -> Bool {
        guard canType(into: target) else { return false }
        operations.append((deletions, insertion))
        text = String(text.dropLast(deletions)) + insertion
        return true
    }
}
