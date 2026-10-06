import AppKit
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TextDeliveryTests: XCTestCase {
    func testCancelledFinalizationDoesNotInsertOrTouchClipboard() async {
        let target = makeTarget(pid: 90)
        let editor = DeliveryFakeLiveTextEditor()
        let pasteboard = DeliveryFakePasteboard()
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: target, frontmost: target),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .inserted),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster(),
            liveTextEditor: editor
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.finalizeLiveTranscript("cancelled", in: target)
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled(restoration: nil))
        XCTAssertTrue(editor.finalizedTexts.isEmpty)
        XCTAssertTrue(pasteboard.replaceTexts.isEmpty)
    }

    func testLiveDraftAndFinalTranscriptReplaceCapturedCursorText() async {
        let target = makeTarget(pid: 91)
        let workspace = DeliveryFakeWorkspace(capturedTarget: target, frontmost: target)
        let accessibility = DeliveryFakeAccessibility(insertionOutcome: .inserted)
        let pasteboard = DeliveryFakePasteboard()
        let liveTextEditor = DeliveryFakeLiveTextEditor()
        let service = makeService(
            workspace: workspace,
            accessibility: accessibility,
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster(),
            liveTextEditor: liveTextEditor
        )

        let updated = await service.updateLiveTranscript("draft", in: target)
        XCTAssertTrue(updated)
        let outcome = await service.finalizeLiveTranscript("final text", in: target)

        XCTAssertEqual(liveTextEditor.updatedTexts, ["draft"])
        XCTAssertEqual(liveTextEditor.finalizedTexts, ["final text"])
        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(accessibility.insertedTargets, [])
        XCTAssertEqual(pasteboard.replaceTexts, [])
    }

    func testCancellingLiveTranscriptRestoresCursorSession() async {
        let target = makeTarget(pid: 92)
        let liveTextEditor = DeliveryFakeLiveTextEditor()
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: target, frontmost: target),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .inserted),
            pasteboard: DeliveryFakePasteboard(),
            eventPoster: DeliveryFakeEventPoster(),
            liveTextEditor: liveTextEditor
        )

        let updated = await service.updateLiveTranscript("temporary", in: target)
        XCTAssertTrue(updated)
        service.cancelLiveTranscript()
        for _ in 0..<100 {
            if liveTextEditor.cancelCount == 1 { break }
            await Task.yield()
        }

        XCTAssertEqual(liveTextEditor.cancelCount, 1)
    }

    func testDirectInsertionUsesCapturedTargetWithoutTouchingClipboard() async {
        let target = makeTarget(pid: 101)
        let workspace = DeliveryFakeWorkspace(capturedTarget: target, frontmost: target)
        let accessibility = DeliveryFakeAccessibility(insertionOutcome: .inserted)
        let pasteboard = DeliveryFakePasteboard()
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: workspace,
            accessibility: accessibility,
            pasteboard: pasteboard,
            eventPoster: eventPoster
        )

        let outcome = await service.deliver("sensitive text", to: target)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(accessibility.insertedTargets, [target])
        XCTAssertEqual(pasteboard.replaceTexts, [])
        XCTAssertEqual(eventPoster.postedTargets, [])
    }

    func testTargetSwitchAndRetryExhaustionNeverPostsToCurrentWrongApp() async {
        let intended = makeTarget(pid: 201)
        let wrong = makeTarget(pid: 202)
        let workspace = DeliveryFakeWorkspace(capturedTarget: intended, frontmost: wrong)
        let pasteboard = DeliveryFakePasteboard()
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: workspace,
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: eventPoster,
            activationAttempts: 3
        )

        let outcome = await service.deliver("copy me", to: intended)

        XCTAssertEqual(outcome, .copiedForManualPaste(.activationFailed))
        XCTAssertEqual(workspace.activationCount, 3)
        XCTAssertEqual(eventPoster.postedTargets, [])
        XCTAssertEqual(pasteboard.currentString, "copy me")
        XCTAssertEqual(pasteboard.restoreCount, 0, "manual-copy policy leaves the transcription available")
    }

    func testSamePIDSameBundleRelaunchWithoutLaunchDateFailsClosed() async {
        let intended = makeTarget(pid: 301)
        let workspace = DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended)
        workspace.availabilityResolver = { target in
            SystemWorkspaceService.targetMatches(
                target,
                processIdentifier: target.processIdentifier,
                bundleIdentifier: target.bundleIdentifier,
                launchDate: nil,
                bundleURL: target.bundleURL
            ) ? .available : .identityChanged
        }
        let pasteboard = DeliveryFakePasteboard()
        let eventPoster = DeliveryFakeEventPoster()
        let accessibility = DeliveryFakeAccessibility(insertionOutcome: .inserted)
        let service = makeService(
            workspace: workspace,
            accessibility: accessibility,
            pasteboard: pasteboard,
            eventPoster: eventPoster
        )

        XCTAssertNil(
            PasteTarget(
                processIdentifier: intended.processIdentifier,
                bundleIdentifier: intended.bundleIdentifier,
                launchDate: nil,
                bundleURL: intended.bundleURL
            ),
            "A target without a process-instance launch token must not be captured"
        )
        let outcome = await service.deliver("copy me", to: intended)

        XCTAssertEqual(outcome, .copiedForManualPaste(.targetIdentityChanged))
        XCTAssertEqual(accessibility.insertedTargets, [])
        XCTAssertEqual(eventPoster.postedTargets, [])
        XCTAssertEqual(pasteboard.currentString, "copy me")
    }

    func testExitedTargetFailsClosedWithManualCopy() async {
        let intended = makeTarget(pid: 302)
        let workspace = DeliveryFakeWorkspace(capturedTarget: intended, frontmost: nil)
        workspace.availability = .exited
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: workspace,
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: DeliveryFakePasteboard(),
            eventPoster: eventPoster
        )

        let outcome = await service.deliver("copy me", to: intended)

        XCTAssertEqual(outcome, .copiedForManualPaste(.targetExited))
        XCTAssertEqual(eventPoster.postedTargets, [])
    }

    func testClosedWindowIsExplicitAndNeverPostsPasteEvent() async {
        let intended = makeTarget(pid: 401)
        let workspace = DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended)
        let accessibility = DeliveryFakeAccessibility(
            insertionOutcome: .noFocusedElement,
            windowAvailability: .closed
        )
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: workspace,
            accessibility: accessibility,
            pasteboard: DeliveryFakePasteboard(),
            eventPoster: eventPoster
        )

        let outcome = await service.deliver("copy me", to: intended)

        XCTAssertEqual(outcome, .copiedForManualPaste(.targetHasNoWindow))
        XCTAssertEqual(eventPoster.postedTargets, [])
    }

    func testSlowActivationIsAwaitedBeforePostingAndRestoringClipboard() async {
        let intended = makeTarget(pid: 501)
        let other = makeTarget(pid: 502)
        let workspace = DeliveryFakeWorkspace(capturedTarget: intended, frontmost: other)
        workspace.frontmostAfterActivationCount = 2
        let pasteboard = DeliveryFakePasteboard()
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: workspace,
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: eventPoster,
            activationAttempts: 4
        )

        let outcome = await service.deliver("paste me", to: intended)

        XCTAssertEqual(outcome, .pasted(restoration: .restored))
        XCTAssertEqual(workspace.activationCount, 2)
        XCTAssertEqual(eventPoster.postedTargets, [intended])
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertNil(pasteboard.currentString)
    }

    func testRejectedActivationIsRetriedButNeverTreatedAsFrontmostConfirmation() async {
        let intended = makeTarget(pid: 551)
        let workspace = DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended)
        workspace.activationOutcome = .rejected
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: workspace,
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: DeliveryFakePasteboard(),
            eventPoster: eventPoster,
            activationAttempts: 3
        )

        let outcome = await service.deliver("manual", to: intended)

        XCTAssertEqual(outcome, .copiedForManualPaste(.activationFailed))
        XCTAssertEqual(workspace.activationCount, 3)
        XCTAssertEqual(eventPoster.postedTargets, [])
    }

    func testPasteboardWriteFailureIsCheckedAndOriginalClipboardRestored() async {
        let intended = makeTarget(pid: 601)
        let pasteboard = DeliveryFakePasteboard()
        pasteboard.replacementFailure = .writeFailed
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster()
        )

        let outcome = await service.deliver("cannot write", to: intended)

        XCTAssertEqual(
            outcome,
            .failed(.pasteboardWriteFailed(.writeFailed, restoration: .restored))
        )
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertNil(pasteboard.currentString)
    }

    func testPasteboardSnapshotFailureStopsBeforeClipboardMutation() async {
        let intended = makeTarget(pid: 651)
        let pasteboard = DeliveryFakePasteboard()
        let failure = PasteboardSnapshotFailure.representationReadFailed(type: "public.rtf")
        pasteboard.snapshotFailure = failure
        let eventPoster = DeliveryFakeEventPoster()
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: eventPoster
        )

        let outcome = await service.deliver("must not replace", to: intended)

        XCTAssertEqual(outcome, .failed(.pasteboardSnapshotFailed(failure)))
        XCTAssertEqual(pasteboard.replaceTexts, [])
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(eventPoster.postedTargets, [])
    }

    func testPerRepresentationRestorationFailureIsNeverReportedAsRestored() async {
        let intended = makeTarget(pid: 652)
        let pasteboard = DeliveryFakePasteboard()
        pasteboard.restorationOutcome = .failed(.representationWriteFailed(type: "public.rtf"))
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster()
        )

        let outcome = await service.deliver("paste", to: intended)

        XCTAssertEqual(
            outcome,
            .pasted(restoration: .failed(.representationWriteFailed(type: "public.rtf")))
        )
        XCTAssertEqual(pasteboard.restoreCount, 1)
    }

    func testSystemRestorationChecksEveryRepresentationBeforeClearingClipboard() {
        let rawType = "public.rtf"
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("TalkTextTests.\(UUID().uuidString)")
        )
        let service = SystemPasteboardService(
            pasteboard: pasteboard,
            representationWriter: { _, _, _ in false }
        )
        let snapshot = PasteboardSnapshot(
            items: [PasteboardItemSnapshot(representations: [rawType: Data("original".utf8)])]
        )
        let originalChangeCount = pasteboard.changeCount

        let outcome = service.restore(snapshot, ifUnchangedSince: originalChangeCount)

        XCTAssertEqual(outcome, .failed(.representationWriteFailed(type: rawType)))
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    }

    func testEventPostFailureLeavesExplicitManualCopy() async {
        let intended = makeTarget(pid: 701)
        let pasteboard = DeliveryFakePasteboard()
        let eventPoster = DeliveryFakeEventPoster()
        eventPoster.postResult = false
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: eventPoster
        )

        let outcome = await service.deliver("manual", to: intended)

        XCTAssertEqual(outcome, .copiedForManualPaste(.eventPostFailed))
        XCTAssertEqual(eventPoster.postedTargets, [intended])
        XCTAssertEqual(pasteboard.currentString, "manual")
        XCTAssertEqual(pasteboard.restoreCount, 0)
    }

    func testClipboardChangeSkipsRestorationWithoutOverwritingNewContents() async {
        let intended = makeTarget(pid: 801)
        let pasteboard = DeliveryFakePasteboard()
        pasteboard.restorationOutcome = .skippedBecauseClipboardChanged
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster()
        )

        let outcome = await service.deliver("paste", to: intended)

        XCTAssertEqual(outcome, .pasted(restoration: .skippedBecauseClipboardChanged))
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertEqual(pasteboard.currentString, "paste")
    }

    func testRapidDeliveriesSerializeEntireClipboardTransaction() async {
        let intended = makeTarget(pid: 901)
        let sleeper = DeliveryGateSleeper()
        let pasteboard = DeliveryFakePasteboard()
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster(),
            sleeper: sleeper
        )

        let first = Task { await service.deliver("first", to: intended) }
        await waitUntil { pasteboard.replaceTexts.count == 1 && sleeper.pendingCount == 1 }
        let second = Task { await service.deliver("second", to: intended) }
        await spinMainActor()

        XCTAssertEqual(pasteboard.replaceTexts, ["first"])

        sleeper.resumeNext()
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .pasted(restoration: .restored))

        await waitUntil { pasteboard.replaceTexts.count == 2 && sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .pasted(restoration: .restored))
        XCTAssertEqual(pasteboard.replaceTexts, ["first", "second"])
        XCTAssertEqual(pasteboard.maximumConcurrentTransactions, 1)
    }

    func testCancelledQueuedDeliveryNeverMutatesClipboardLater() async {
        let intended = makeTarget(pid: 1_001)
        let sleeper = DeliveryGateSleeper()
        let pasteboard = DeliveryFakePasteboard()
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster(),
            sleeper: sleeper
        )

        let first = Task { await service.deliver("first", to: intended) }
        await waitUntil { pasteboard.replaceTexts == ["first"] && sleeper.pendingCount == 1 }
        let cancelled = Task { await service.deliver("must never write", to: intended) }
        await spinMainActor()
        cancelled.cancel()

        let cancelledOutcome = await cancelled.value
        XCTAssertEqual(cancelledOutcome, .cancelled(restoration: nil))
        XCTAssertEqual(pasteboard.replaceTexts, ["first"])

        sleeper.resumeNext()
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        _ = await first.value
        await spinMainActor()
        XCTAssertEqual(pasteboard.replaceTexts, ["first"])
    }

    func testCancellationAfterQueueHandoffReleasesTransactionForNextDelivery() async {
        let intended = makeTarget(pid: 1_101)
        let sleeper = DeliveryGateSleeper()
        let pasteboard = DeliveryFakePasteboard()
        let service = makeService(
            workspace: DeliveryFakeWorkspace(capturedTarget: intended, frontmost: intended),
            accessibility: DeliveryFakeAccessibility(insertionOutcome: .targetNotFocused),
            pasteboard: pasteboard,
            eventPoster: DeliveryFakeEventPoster(),
            sleeper: sleeper
        )

        let first = Task { await service.deliver("first", to: intended) }
        await waitUntil { pasteboard.replaceTexts == ["first"] && sleeper.pendingCount == 1 }
        let handedOff = Task { await service.deliver("second", to: intended) }

        sleeper.resumeNext()
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        _ = await first.value
        await waitUntil { pasteboard.replaceTexts == ["first", "second"] && sleeper.pendingCount == 1 }

        handedOff.cancel()
        sleeper.resumeNext(with: false)
        let cancelledOutcome = await handedOff.value
        XCTAssertEqual(cancelledOutcome, .cancelled(restoration: .restored))

        let third = Task { await service.deliver("third", to: intended) }
        await waitUntil { pasteboard.replaceTexts == ["first", "second", "third"] && sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        await waitUntil { sleeper.pendingCount == 1 }
        sleeper.resumeNext()
        let thirdOutcome = await third.value
        XCTAssertEqual(thirdOutcome, .pasted(restoration: .restored))
        XCTAssertEqual(pasteboard.maximumConcurrentTransactions, 1)
    }

    private func makeService(
        workspace: DeliveryFakeWorkspace,
        accessibility: DeliveryFakeAccessibility,
        pasteboard: DeliveryFakePasteboard,
        eventPoster: DeliveryFakeEventPoster,
        liveTextEditor: any LiveTextEditing = DeliveryFakeLiveTextEditor(),
        sleeper: any DeliverySleeping = DeliveryImmediateSleeper(),
        activationAttempts: Int = 3
    ) -> TextDeliveryService {
        TextDeliveryService(
            workspace: workspace,
            accessibility: accessibility,
            pasteboard: pasteboard,
            eventPoster: eventPoster,
            liveTextEditor: liveTextEditor,
            sleeper: sleeper,
            activationAttempts: activationAttempts,
            activationRetryDelay: 0,
            restorationDelay: 0
        )
    }

    private func makeTarget(pid: pid_t) -> PasteTarget {
        PasteTarget(
            processIdentifier: pid,
            bundleIdentifier: "test.app.\(pid)",
            launchDate: Date(timeIntervalSince1970: TimeInterval(pid)),
            bundleURL: URL(fileURLWithPath: "/Applications/Test-\(pid).app")
        )!
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private func spinMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}
