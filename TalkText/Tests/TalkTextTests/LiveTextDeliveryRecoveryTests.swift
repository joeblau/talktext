import AppKit
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class LiveTextDeliveryRecoveryTests: XCTestCase {
    func testFinalWriteFallsBackOnceAfterSuccessfullyRestoringDraft() async throws {
        let target = try XCTUnwrap(PasteTarget(processIdentifier: getpid(), bundleIdentifier: "test.editor",
                                               launchDate: Date(), bundleURL: nil))
        let editor = DeliveryFakeLiveTextEditor()
        editor.finalizationOutcome = .unavailable
        let accessibility = DeliveryFakeAccessibility(insertionOutcome: .inserted)
        let pasteboard = DeliveryFakePasteboard()
        let service = TextDeliveryService(workspace: DeliveryFakeWorkspace(capturedTarget: target, frontmost: target),
                                          accessibility: accessibility, pasteboard: pasteboard, liveTextEditor: editor)

        let outcome = await service.finalizeLiveTranscript("final transcript", in: target)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(editor.cancelCount, 1)
        XCTAssertEqual(accessibility.insertedTargets, [target])
        XCTAssertTrue(pasteboard.replaceTexts.isEmpty)
    }

    func testFinalTextIsCopiedWithoutPastingOverAnUnrestoredLiveDraft() async throws {
        let target = try XCTUnwrap(PasteTarget(processIdentifier: getpid(), bundleIdentifier: Bundle.main.bundleIdentifier,
                                               launchDate: Date(), bundleURL: Bundle.main.bundleURL))
        let editor = DeliveryFakeLiveTextEditor()
        editor.finalizationOutcome = .unavailable
        editor.cancellationOutcome = .unavailable
        let pasteboard = DeliveryFakePasteboard()
        let workspace = DeliveryFakeWorkspace(capturedTarget: target, frontmost: target)
        let accessibility = DeliveryFakeAccessibility(insertionOutcome: .inserted)
        let eventPoster = DeliveryFakeEventPoster()
        let service = TextDeliveryService(workspace: workspace, accessibility: accessibility,
                                          pasteboard: pasteboard, eventPoster: eventPoster, liveTextEditor: editor)
        let outcome = await service.finalizeLiveTranscript("final transcript", in: target)
        XCTAssertEqual(outcome, .copiedForManualPaste(.liveDraftChanged))
        XCTAssertEqual(editor.cancelCount, 1)
        XCTAssertEqual(editor.finalizedTexts, ["final transcript"])
        XCTAssertEqual(workspace.activationCount, 0)
        XCTAssertEqual(pasteboard.currentString, "final transcript")
        XCTAssertTrue(accessibility.insertedTargets.isEmpty)
        XCTAssertTrue(eventPoster.postedTargets.isEmpty)
    }
}
