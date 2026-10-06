import AppKit
import Darwin
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TranscriptionEngineStateTests: XCTestCase {
    func testRightOptionReleaseDuringPreflightCancelsPendingRecordingStart() async {
        let preflight = EnginePreflightFake(result: nil)
        let factory = EngineRecorderFactoryFake()
        let engine = makeEngine(preflight: preflight, factory: factory)

        engine.startRecording()
        XCTAssertEqual(engine.state, .starting)

        engine.stopRecording()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.statusText, "Ready. Hold Right Option to record, double-tap to lock")

        preflight.resolve(EngineFixtures.readyPreflightResult)
        await spinMainActor()
        XCTAssertEqual(factory.creationCount, 0)
    }

    func testDependenciesArePreflightedBeforePermissionOrRecorderSideEffects() async {
        let preflight = EnginePreflightFake(result: nil)
        let permission = EnginePermissionFake()
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            preflight: preflight,
            permission: permission,
            factory: factory,
            store: store
        )

        engine.toggleRecording()

        XCTAssertEqual(engine.state, .starting)
        XCTAssertEqual(permission.statusCallCount, 0)
        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertEqual(store.allocatedURLs.count, 0)

        preflight.resolve(EngineFixtures.readyPreflightResult)
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(permission.statusCallCount, 1)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(store.allocatedURLs.count, 1)
    }

    func testPreflightFailureIsActionableAndFailsBeforeMicrophonePermission() async {
        let failure = TalkTextDependencyPreflightFailure.missingModel(
            searchedPaths: ["/private/fixture/parakeet"]
        )
        let preflight = EnginePreflightFake(result: .failure(failure))
        let permission = EnginePermissionFake()
        let factory = EngineRecorderFactoryFake()
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            preflight: preflight,
            permission: permission,
            factory: factory,
            store: store
        )

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertTrue(engine.statusText.contains("Parakeet"))
        XCTAssertEqual(engine.modelRecovery, .setup)
        XCTAssertEqual(permission.statusCallCount, 0)
        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertEqual(store.allocatedURLs.count, 0)
    }

    func testLaunchPreparationIsCachedButEveryRecordingRevalidatesDependencies() async {
        let preflight = EnginePreflightFake()
        let engine = makeEngine(preflight: preflight)

        engine.prepareDependencies()
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(preflight.invocationCount, 1)

        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(preflight.invocationCount, 2)
    }

    func testRepeatedTogglesWhilePermissionPendingCannotStartMultipleRecorders() async {
        let permission = EnginePermissionFake(status: .notDetermined)
        let factory = EngineRecorderFactoryFake()
        let engine = makeEngine(permission: permission, factory: factory)

        engine.toggleRecording()
        await waitUntil {
            engine.state == .requestingPermission && permission.requestCount == 1
        }
        engine.toggleRecording()
        engine.toggleRecording()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(factory.creationCount, 0)

        permission.resolveAccess(granted: true)
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(factory.creationCount, 1)
    }

    func testPermissionCallbackAfterCancellationCannotStartRecorder() async {
        let permission = EnginePermissionFake(status: .notDetermined)
        let factory = EngineRecorderFactoryFake()
        let engine = makeEngine(permission: permission, factory: factory)

        engine.toggleRecording()
        await waitUntil { engine.state == .requestingPermission }
        engine.cancelCurrentOperation()
        permission.resolveAccess(granted: true)
        await spinMainActor()

        XCTAssertEqual(engine.state, .failed)
        XCTAssertEqual(factory.creationCount, 0)
    }

    func testDeniedRestrictedAndUnknownPermissionFailClosed() async {
        let cases: [(MicrophoneAuthorization, String)] = [
            (.denied, "denied"),
            (.restricted, "restricted"),
            (.unknown, "could not be determined"),
        ]

        for (authorization, expectedText) in cases {
            let factory = EngineRecorderFactoryFake()
            let engine = makeEngine(
                permission: EnginePermissionFake(status: authorization),
                factory: factory
            )
            engine.toggleRecording()
            await waitUntil { engine.state == .failed }

            XCTAssertTrue(engine.statusText.localizedCaseInsensitiveContains(expectedText))
            XCTAssertEqual(factory.creationCount, 0)
        }
    }

    func testRecorderStartFailureCleansSessionFileAndShowsFailure() async {
        let recorder = EngineRecorderFake()
        recorder.startResult = false
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: store
        )

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(store.allocatedURLs.count, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        XCTAssertTrue(engine.statusText.contains("could not start"))
    }

    func testRecorderConstructionFailureCleansAllocatedSessionFile() async {
        let factory = EngineRecorderFactoryFake()
        factory.creationError = CocoaError(.fileWriteUnknown)
        let store = EngineFileStoreFake()
        let engine = makeEngine(factory: factory, store: store)

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        XCTAssertTrue(engine.statusText.contains("could not be created"))
    }

    func testSynchronousRecorderCompletionDuringStartCannotReportRecording() async {
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        recorder.onStart = { factory.emit(.unexpectedCompletion) }
        let store = EngineFileStoreFake()
        let engine = makeEngine(factory: factory, store: store)

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(store.removedURLs.count, 1)
        XCTAssertTrue(engine.statusText.contains("unexpectedly"))
    }

    func testRecorderFailureCallbacksAreVisibleAndAlwaysCleanAudio() async {
        let events: [RecorderEvent] = [
            .interrupted,
            .deviceUnavailable,
            .encodeError(RecorderErrorDiagnostic(domain: "fixture", code: 7)),
            .unexpectedCompletion,
        ]

        for event in events {
            let recorder = EngineRecorderFake()
            let store = EngineFileStoreFake()
            let factory = EngineRecorderFactoryFake(recorders: [recorder])
            let engine = makeEngine(factory: factory, store: store)
            engine.toggleRecording()
            await waitUntil { engine.state == .recording }

            factory.emit(event)

            XCTAssertEqual(engine.state, .failed)
            XCTAssertEqual(store.removedURLs.count, 1)
            XCTAssertFalse(recorder.isRecording)
            XCTAssertEqual(recorder.cancelCount, 1)
        }
    }

    func testEveryRecorderStopFailureCleansAllocatedSessionFile() async {
        let failures: [RecorderStopOutcome] = [
            .notRecording,
            .encodeError(RecorderErrorDiagnostic(domain: "fixture", code: 17)),
            .unsuccessfulCompletion,
            .finalizationTimedOut,
            .cancelled,
        ]

        for failure in failures {
            let recorder = EngineRecorderFake()
            recorder.immediateStopOutcome = failure
            let store = EngineFileStoreFake()
            let engine = makeEngine(
                factory: EngineRecorderFactoryFake(recorders: [recorder]),
                store: store
            )
            engine.toggleRecording()
            await waitUntil { engine.state == .recording }

            engine.toggleRecording()
            await waitUntil { engine.state == .failed }

            XCTAssertEqual(store.allocatedURLs.count, 1)
            XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        }
    }

    func testRecorderCallbackRaceWhileStoppingCannotAdvanceStaleSuccess() async {
        let recorder = EngineRecorderFake()
        recorder.immediateStopOutcome = nil
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let store = EngineFileStoreFake()
        let transcriber = EngineTranscriberFake(outcome: nil)
        let engine = makeEngine(
            factory: factory,
            store: store,
            transcriber: transcriber
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }

        engine.toggleRecording()
        await waitUntil { recorder.stopCount == 1 && engine.state == .stopping }
        factory.emit(.encodeError(RecorderErrorDiagnostic(domain: "fixture", code: 9)))
        recorder.completeStop(with: .finished)
        await spinMainActor()

        XCTAssertEqual(engine.state, .failed)
        XCTAssertEqual(transcriber.invocationCount, 0)
        XCTAssertEqual(store.removedURLs.count, 1)
    }

    func testMaximumDurationFinalizesThenTranscribesExactlyOnce() async {
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let store = EngineFileStoreFake()
        let transcriber = EngineTranscriberFake(outcome: nil)
        let engine = makeEngine(
            factory: factory,
            store: store,
            transcriber: transcriber
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }

        factory.emit(.maximumDurationReached)
        await waitUntil { engine.state == .transcribing && transcriber.invocationCount == 1 }

        XCTAssertEqual(recorder.maximumDurations, [TranscriptionEngine.maximumRecordingDuration])
        transcriber.resolve(.noSpeech)
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(store.removedURLs.count, 1)
    }

    func testRecordingReplacesTextAtCursorButOnlyFinalizesCompleteTranscript() async {
        let snapshotter = EngineSnapshotterFake(result: true)
        let transcriber = EngineSequencedTranscriberFake(
            outcomes: [.success("A live draft"), .success("The final transcript")]
        )
        let store = EngineFileStoreFake()
        let delivery = EngineDeliveryFake()
        delivery.liveUpdateResult = false
        let engine = makeEngine(
            store: store,
            snapshotter: snapshotter,
            transcriber: transcriber,
            delivery: delivery,
            livePreviewInterval: 0.01
        )

        engine.toggleRecording()
        await waitUntilWithDelay { delivery.liveUpdatedTexts == ["", "A live draft"] }

        XCTAssertEqual(engine.state, .recording)
        XCTAssertEqual(snapshotter.requests.count, 1)
        XCTAssertEqual(delivery.deliveredTexts, [], "A draft must not run final delivery")
        XCTAssertEqual(store.removedURLs, [snapshotter.requests[0].destination])

        engine.toggleRecording()
        await waitUntilWithDelay { engine.state == .idle }

        XCTAssertEqual(transcriber.audioURLs.count, 2)
        XCTAssertEqual(transcriber.audioURLs[0], snapshotter.requests[0].destination)
        XCTAssertEqual(transcriber.audioURLs[1], snapshotter.requests[0].source)
        XCTAssertEqual(delivery.finalizedTexts, ["The final transcript"])
        XCTAssertEqual(delivery.deliveredTexts, ["The final transcript"])
        XCTAssertEqual(Set(store.removedURLs), Set(store.allocatedURLs))
    }

    func testRapidTogglesCannotStartAnotherSessionWhileDeliveryIsPending() async {
        let store = EngineFileStoreFake()
        let delivery = EngineDeliveryFake(outcome: nil)
        let factory = EngineRecorderFactoryFake(
            recorders: [EngineRecorderFake(), EngineRecorderFake()]
        )
        let engine = makeEngine(
            factory: factory,
            store: store,
            transcriber: EngineTranscriberFake(outcome: .success("secret")),
            delivery: delivery
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }

        engine.toggleRecording()
        await waitUntil { engine.state == .delivering && delivery.deliveredTexts.count == 1 }

        XCTAssertFalse(engine.isInteractive)
        XCTAssertEqual(store.removedURLs.count, 1)
        engine.toggleRecording()
        engine.toggleRecording()
        engine.toggleRecording()
        await spinMainActor()

        XCTAssertEqual(delivery.captureCount, 1, "No second session may start")
        XCTAssertEqual(factory.creationCount, 1, "No second recorder may start")
        XCTAssertEqual(delivery.deliveredTexts, ["secret"], "No second delivery may start")

        delivery.resolve(.inserted)
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(engine.statusText, "Inserted! Hold Right Option to record, double-tap to lock")

        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(delivery.captureCount, 2)
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(delivery.deliveredTexts, ["secret"])
        engine.cancelCurrentOperation()
    }

    func testEveryTranscriptionTerminalOutcomeCleansRecording() async {
        let outcomes: [(TranscriptionOutcome, TranscriptionEngine.State)] = [
            (.noSpeech, .idle),
            (.modelUnavailable(.missingModel(searchedPaths: [])), .failed),
            (.invalidAudio(.empty), .failed),
            (.inferenceFailed(TranscriptionDiagnostic(domain: "test", code: 3)), .failed),
            (.cancelled, .failed),
        ]

        for (outcome, expectedState) in outcomes {
            let store = EngineFileStoreFake()
            let engine = makeEngine(
                store: store,
                transcriber: EngineTranscriberFake(outcome: outcome)
            )
            engine.toggleRecording()
            await waitUntil { engine.state == .recording }
            engine.toggleRecording()
            await waitUntil { engine.state == expectedState && !store.removedURLs.isEmpty }

            XCTAssertEqual(store.removedURLs.count, 1)
        }
    }

    func testCancellationAndNormalTerminationCleanActiveAudio() async {
        let recordingStore = EngineFileStoreFake()
        let recorder = EngineRecorderFake()
        let recordingEngine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: recordingStore
        )
        recordingEngine.toggleRecording()
        await waitUntil { recordingEngine.state == .recording }

        recordingEngine.cancelCurrentOperation()

        XCTAssertEqual(recordingEngine.state, .failed)
        XCTAssertEqual(recordingStore.removedURLs.count, 1)
        XCTAssertEqual(recorder.cancelCount, 1)

        let terminationStore = EngineFileStoreFake()
        let terminationRecorder = EngineRecorderFake()
        let terminationEngine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [terminationRecorder]),
            store: terminationStore
        )
        terminationEngine.toggleRecording()
        await waitUntil { terminationEngine.state == .recording }

        terminationEngine.cleanup()

        XCTAssertEqual(terminationStore.removedURLs.count, 1)
        XCTAssertEqual(terminationStore.instanceCleanupCount, 1)
        XCTAssertEqual(terminationRecorder.cancelCount, 1)
    }

    func testCancellationCleansAudioFromEveryFileOwningActiveState() async {
        for activeState in FileOwningActiveState.allCases {
            await assertSessionCleanup(from: activeState, action: .cancel)
        }
    }

    func testApplicationTerminationCleansAudioFromEveryFileOwningActiveState() async {
        for activeState in FileOwningActiveState.allCases {
            await assertSessionCleanup(from: activeState, action: .terminateApplication)
        }
    }

    func testApplicationTerminationCancelsNativeTranscriptionAndUninstallsHotkey() async {
        let transcriber = EngineTranscriberFake(outcome: nil)
        let store = EngineFileStoreFake()
        let engine = makeEngine(store: store, transcriber: transcriber)
        let hotKeyService = EngineHotKeyServiceFake()
        let delegate = AppDelegate(transcriptionEngine: engine, hotKeyController: HotKeyController(service: hotKeyService))
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        engine.toggleRecording()
        await waitUntil { engine.state == .transcribing }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(transcriber.synchronousCancellationCount, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        XCTAssertEqual(hotKeyService.uninstallCount, 1)
        transcriber.resolve(.cancelled)
        await spinMainActor()
    }

    private func makeEngine(
        preflight: EnginePreflightFake = EnginePreflightFake(),
        permission: EnginePermissionFake = EnginePermissionFake(),
        recordingReadyCue: any RecordingReadyCuePlaying = EngineReadyCueFake(),
        factory: EngineRecorderFactoryFake = EngineRecorderFactoryFake(),
        store: EngineFileStoreFake = EngineFileStoreFake(),
        snapshotter: any ActiveRecordingSnapshotting = EngineSnapshotterFake(),
        transcriber: any SpeechTranscribing = EngineTranscriberFake(),
        delivery: EngineDeliveryFake = EngineDeliveryFake(),
        livePreviewInterval: TimeInterval = 1.5
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            permissionProvider: permission,
            recorderFactory: factory,
            recordingReadyCue: recordingReadyCue,
            recordingStoppedCue: EngineStoppedCueFake(),
            recordingFileStore: store,
            recordingSnapshotter: snapshotter,
            dependencyPreflight: preflight,
            transcriber: transcriber,
            textDelivery: delivery,
            livePreviewInterval: livePreviewInterval,
            performStartupCleanup: false
        )
    }

    private enum FileOwningActiveState: CaseIterable, Equatable {
        case stopping
        case transcribing
        case delivering
    }

    private enum SessionCleanupAction: Equatable {
        case cancel
        case terminateApplication
    }

    private func assertSessionCleanup(
        from activeState: FileOwningActiveState,
        action: SessionCleanupAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = EngineRecorderFake()
        let transcriber: EngineTranscriberFake
        let delivery: EngineDeliveryFake
        switch activeState {
        case .stopping:
            recorder.immediateStopOutcome = nil
            transcriber = EngineTranscriberFake()
            delivery = EngineDeliveryFake()
        case .transcribing:
            transcriber = EngineTranscriberFake(outcome: nil)
            delivery = EngineDeliveryFake()
        case .delivering:
            transcriber = EngineTranscriberFake(outcome: .success("fixture transcript"))
            delivery = EngineDeliveryFake(outcome: nil)
        }

        let store = EngineFileStoreFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: store,
            transcriber: transcriber,
            delivery: delivery
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        engine.toggleRecording()

        switch activeState {
        case .stopping:
            await waitUntil { engine.state == .stopping && recorder.stopCount == 1 }
        case .transcribing:
            await waitUntil {
                engine.state == .transcribing && transcriber.invocationCount == 1
            }
        case .delivering:
            await waitUntil {
                engine.state == .delivering && delivery.deliveredTexts.count == 1
            }
        }

        switch action {
        case .cancel:
            engine.cancelCurrentOperation()
        case .terminateApplication:
            engine.cleanup()
        }

        XCTAssertEqual(store.allocatedURLs.count, 1, file: file, line: line)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs, file: file, line: line)
        XCTAssertEqual(
            store.instanceCleanupCount,
            action == .terminateApplication ? 1 : 0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            transcriber.synchronousCancellationCount,
            action == .terminateApplication ? 1 : 0,
            file: file,
            line: line
        )

        if activeState == .delivering {
            delivery.resolve(.inserted)
            await spinMainActor()
        }
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
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func waitUntilWithDelay(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}
