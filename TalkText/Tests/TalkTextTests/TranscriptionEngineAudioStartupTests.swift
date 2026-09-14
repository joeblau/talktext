import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TranscriptionEngineAudioStartupTests: XCTestCase {
    func testAutomaticStopRejectsSilentAndInvalidLevels() async {
        for peak: Float in [-80, -.infinity, .nan, .infinity] {
            let recorder = EngineRecorderFake()
            recorder.peakLevel = peak
            let factory = EngineRecorderFactoryFake(recorders: [recorder])
            let store = EngineFileStoreFake()
            let transcriber = EngineTranscriberFake(outcome: .success("hallucination"))
            let engine = makeEngine(factory: factory, store: store, transcriber: transcriber)
            engine.startRecording()
            await waitUntil { engine.state == .recording }
            factory.emit(.maximumDurationReached)
            await spinMainActor()
            XCTAssertEqual(engine.state, .failed)
            XCTAssertEqual(transcriber.invocationCount, 0)
            XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        }
    }

    func testLateRecorderErrorsCannotCancelFinalTranscription() async {
        let factory = EngineRecorderFactoryFake()
        let transcriber = EngineTranscriberFake(outcome: nil)
        let delivery = EngineDeliveryFake()
        let engine = makeEngine(factory: factory, transcriber: transcriber, delivery: delivery)
        engine.startRecording()
        await waitUntil { engine.state == .recording }
        engine.stopRecording()
        await waitUntil { engine.state == .transcribing && transcriber.invocationCount == 1 }
        factory.emit(.deviceUnavailable)
        factory.emit(.unexpectedCompletion)
        XCTAssertEqual(engine.state, .transcribing)
        transcriber.resolve(.success("Finished transcript"))
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(delivery.finalizedTexts, ["Finished transcript"])
    }

    func testRightOptionStartAndStopIntentsRecordAndTranscribe() async {
        let recorder = EngineRecorderFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder])
        )

        engine.startRecording()
        await waitUntil { engine.state == .recording }
        engine.stopRecording()
        await waitUntil { engine.state == .idle }

        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testRecorderMustVerifyInputReadinessBeforeEngineReportsRecording() async {
        let recorder = EngineRecorderFake()
        recorder.completesStartImmediately = false
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder])
        )

        engine.startRecording()
        await waitUntil { recorder.startCount == 1 }

        XCTAssertEqual(engine.state, .starting)
        XCTAssertFalse(recorder.isRecording)

        recorder.completeStart(with: true)
        await waitUntil { engine.state == .recording }

        XCTAssertTrue(recorder.isRecording)
        engine.cancelCurrentOperation()
    }

    func testRightOptionReleaseWhileMicrophoneRoutePreparesCancelsLateReadiness() async {
        let recorder = EngineRecorderFake()
        recorder.completesPreparationImmediately = false
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: store
        )

        engine.startRecording()
        await waitUntil { recorder.preparationCount == 1 }
        engine.stopRecording()
        await spinMainActor()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertGreaterThanOrEqual(recorder.cancelCount, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)

        recorder.completePreparation(with: true)
        await spinMainActor()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(recorder.startCount, 0)
    }

    func testRightOptionReleaseWhileRecorderWaitsForAudioCancelsLateStartup() async {
        let recorder = EngineRecorderFake()
        recorder.completesStartImmediately = false
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: store
        )

        engine.startRecording()
        await waitUntil { recorder.startCount == 1 }
        engine.stopRecording()
        await spinMainActor()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertGreaterThanOrEqual(recorder.cancelCount, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)

        // A driver callback already queued before cancellation cannot revive
        // the discarded recording session.
        recorder.completeStart(with: true)
        await spinMainActor()
        XCTAssertEqual(engine.state, .idle)
    }

    func testSilentRecordingNamesTheInputInsteadOfTranscribingHallucinations() async {
        let recorder = EngineRecorderFake()
        recorder.peakLevel = -80
        recorder.inputDeviceName = "MacBook Pro Microphone"
        let transcriber = EngineTranscriberFake(outcome: .success("you"))
        let delivery = EngineDeliveryFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            transcriber: transcriber,
            delivery: delivery
        )

        engine.startRecording()
        await waitUntil { engine.state == .recording }
        engine.stopRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(transcriber.invocationCount, 0)
        XCTAssertTrue(delivery.finalizedTexts.isEmpty)
        XCTAssertTrue(engine.statusText.contains("MacBook Pro Microphone"))
    }

    func testAudibleRecordingAtTheSilenceFloorStillTranscribes() async {
        let recorder = EngineRecorderFake()
        recorder.peakLevel = TranscriptionEngine.silenceFloor + 1
        let transcriber = EngineTranscriberFake(outcome: .success("hello"))
        let delivery = EngineDeliveryFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            transcriber: transcriber,
            delivery: delivery
        )

        engine.startRecording()
        await waitUntil { engine.state == .recording }
        engine.stopRecording()
        await waitUntil { engine.state == .idle }

        XCTAssertEqual(transcriber.invocationCount, 1)
        XCTAssertEqual(delivery.finalizedTexts, ["hello"])
    }

    func testMissingInputDeviceFailsWithAPickerHint() async {
        let factory = EngineRecorderFactoryFake(recorders: [])
        factory.creationError = AudioRecorderCreationError.noInputDevice
        let engine = makeEngine(factory: factory)

        engine.startRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertTrue(engine.statusText.contains("No microphone is available"))
        XCTAssertTrue(engine.statusText.contains("Input"))
    }

    private func makeEngine(
        preflight: EnginePreflightFake = EnginePreflightFake(),
        permission: EnginePermissionFake = EnginePermissionFake(),
        recordingReadyCue: any RecordingReadyCuePlaying = EngineReadyCueFake(),
        factory: EngineRecorderFactoryFake = EngineRecorderFactoryFake(),
        store: EngineFileStoreFake = EngineFileStoreFake(),
        snapshotter: any ActiveRecordingSnapshotting = EngineSnapshotterFake(),
        transcriber: any WhisperTranscribing = EngineTranscriberFake(),
        delivery: EngineDeliveryFake = EngineDeliveryFake(),
        livePreviewInterval: TimeInterval = 1.5
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            permissionProvider: permission,
            recorderFactory: factory,
            recordingReadyCue: recordingReadyCue,
            recordingFileStore: store,
            recordingSnapshotter: snapshotter,
            dependencyPreflight: preflight,
            transcriber: transcriber,
            textDelivery: delivery,
            livePreviewInterval: livePreviewInterval,
            performStartupCleanup: false
        )
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
}
