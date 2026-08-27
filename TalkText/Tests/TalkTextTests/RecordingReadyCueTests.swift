import XCTest
@testable import TalkText

@MainActor
final class RecordingReadyCueTests: XCTestCase {
    func testReadyChimeCompletesBeforeMicrophoneCaptureBegins() async {
        let cue = EngineReadyCueFake(completesImmediately: false)
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let engine = makeEngine(recordingReadyCue: cue, factory: factory)

        engine.startRecording()
        await waitUntil { cue.playCount == 1 }

        XCTAssertEqual(engine.state, .starting)
        XCTAssertEqual(engine.statusText, "Ready to record…")
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(recorder.preparationCount, 1)
        XCTAssertEqual(recorder.startCount, 0)

        cue.complete()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(recorder.startCount, 1)
        engine.cancelCurrentOperation()
    }

    func testReadyChimeWaitsUntilTheMicrophoneHasProducedInput() async {
        let cue = EngineReadyCueFake(completesImmediately: false)
        let recorder = EngineRecorderFake()
        recorder.completesPreparationImmediately = false
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let engine = makeEngine(recordingReadyCue: cue, factory: factory)

        engine.startRecording()
        await waitUntil { recorder.preparationCount == 1 }

        XCTAssertEqual(cue.playCount, 0)
        XCTAssertEqual(engine.statusText, "Connecting to microphone…")

        recorder.completePreparation(with: true)
        await waitUntil { cue.playCount == 1 }
        XCTAssertEqual(engine.statusText, "Ready to record…")
        engine.cancelCurrentOperation()
    }

    func testRightOptionReleaseDuringReadyChimeCancelsPreparedMicrophone() async {
        let cue = EngineReadyCueFake(completesImmediately: false)
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let engine = makeEngine(recordingReadyCue: cue, factory: factory)

        engine.startRecording()
        await waitUntil { cue.playCount == 1 }
        engine.stopRecording()
        await spinMainActor()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(cue.stopCount, 1)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertGreaterThanOrEqual(recorder.cancelCount, 1)
    }

    private func makeEngine(
        recordingReadyCue: any RecordingReadyCuePlaying,
        factory: EngineRecorderFactoryFake
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            permissionProvider: EnginePermissionFake(),
            recorderFactory: factory,
            recordingReadyCue: recordingReadyCue,
            recordingFileStore: EngineFileStoreFake(),
            recordingSnapshotter: EngineSnapshotterFake(),
            dependencyPreflight: EnginePreflightFake(),
            transcriber: EngineTranscriberFake(),
            textDelivery: EngineDeliveryFake(),
            performStartupCleanup: false
        )
    }

    private func spinMainActor() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
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
