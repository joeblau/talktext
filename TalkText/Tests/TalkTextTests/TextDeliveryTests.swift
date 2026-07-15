import AppKit
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TextDeliveryTests: XCTestCase {
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
        sleeper: any DeliverySleeping = DeliveryImmediateSleeper(),
        activationAttempts: Int = 3
    ) -> TextDeliveryService {
        TextDeliveryService(
            workspace: workspace,
            accessibility: accessibility,
            pasteboard: pasteboard,
            eventPoster: eventPoster,
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

@MainActor
private final class DeliveryFakeWorkspace: WorkspaceServing {
    let capturedTarget: PasteTarget?
    var frontmost: PasteTarget?
    var availability: TargetProcessAvailability = .available
    var availabilitySequence: [TargetProcessAvailability] = []
    var availabilityResolver: ((PasteTarget) -> TargetProcessAvailability)?
    var activationOutcome: TargetActivationOutcome = .requested
    var frontmostAfterActivationCount: Int?
    private(set) var activationCount = 0

    init(capturedTarget: PasteTarget?, frontmost: PasteTarget?) {
        self.capturedTarget = capturedTarget
        self.frontmost = frontmost
    }

    func currentExternalTarget(excludingBundleIdentifier: String?) -> PasteTarget? {
        capturedTarget
    }

    func availability(of target: PasteTarget) -> TargetProcessAvailability {
        if let availabilityResolver {
            return availabilityResolver(target)
        }
        if !availabilitySequence.isEmpty {
            return availabilitySequence.removeFirst()
        }
        return availability
    }

    func activate(_ target: PasteTarget) -> TargetActivationOutcome {
        activationCount += 1
        if let threshold = frontmostAfterActivationCount, activationCount >= threshold {
            frontmost = target
        }
        return activationOutcome
    }

    func frontmostTarget() -> PasteTarget? {
        frontmost
    }
}

@MainActor
private final class DeliveryFakeAccessibility: AccessibilityServing {
    var permission = true
    var insertionOutcome: AccessibilityInsertionOutcome
    var windowAvailabilityValue: TargetWindowAvailability
    private(set) var insertedTargets: [PasteTarget] = []

    init(
        insertionOutcome: AccessibilityInsertionOutcome,
        windowAvailability: TargetWindowAvailability = .available
    ) {
        self.insertionOutcome = insertionOutcome
        windowAvailabilityValue = windowAvailability
    }

    func ensurePermission(prompt: Bool) -> Bool {
        permission
    }

    func insert(_ text: String, into target: PasteTarget) -> AccessibilityInsertionOutcome {
        insertedTargets.append(target)
        return insertionOutcome
    }

    func windowAvailability(of target: PasteTarget) -> TargetWindowAvailability {
        windowAvailabilityValue
    }
}

@MainActor
private final class DeliveryFakeEventPoster: PasteEventPosting {
    var permission = true
    var postResult = true
    private(set) var postedTargets: [PasteTarget] = []

    func ensurePermission(prompt: Bool) -> Bool {
        permission
    }

    func postPasteShortcut(to target: PasteTarget) -> Bool {
        postedTargets.append(target)
        return postResult
    }
}

@MainActor
private final class DeliveryFakePasteboard: PasteboardServing {
    private(set) var changeCount = 1
    private(set) var currentString: String?
    private(set) var replaceTexts: [String] = []
    private(set) var restoreCount = 0
    private(set) var maximumConcurrentTransactions = 0
    var replacementFailure: PasteboardMutationFailure?
    var snapshotFailure: PasteboardSnapshotFailure?
    var restorationOutcome: ClipboardRestorationOutcome = .restored
    private var transactionDepth = 0

    func snapshot() -> Result<PasteboardSnapshot, PasteboardSnapshotFailure> {
        if let snapshotFailure {
            return .failure(snapshotFailure)
        }
        transactionDepth += 1
        maximumConcurrentTransactions = max(maximumConcurrentTransactions, transactionDepth)
        return .success(
            PasteboardSnapshot(
                items: [PasteboardItemSnapshot(representations: ["public.utf8-plain-text": Data("original".utf8)])]
            )
        )
    }

    func replaceContents(with text: String) -> PasteboardReplacementResult {
        replaceTexts.append(text)
        changeCount += 1
        if let replacementFailure {
            return .failed(replacementFailure, currentChangeCount: changeCount)
        }
        currentString = text
        return .replaced(changeCount: changeCount)
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifUnchangedSince changeCount: Int
    ) -> ClipboardRestorationOutcome {
        restoreCount += 1
        transactionDepth = max(0, transactionDepth - 1)
        if restorationOutcome == .restored {
            currentString = nil
            self.changeCount += 1
        }
        return restorationOutcome
    }
}

@MainActor
private final class DeliveryImmediateSleeper: DeliverySleeping {
    func sleep(for duration: TimeInterval) async -> Bool {
        !Task.isCancelled
    }
}

@MainActor
private final class DeliveryGateSleeper: DeliverySleeping {
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func sleep(for duration: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(with result: Bool = true) {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(returning: result)
    }
}
