import AVFoundation
import XCTest
@testable import TalkText

@MainActor
final class RecordingReadyCueTests: XCTestCase {
    func testReadyAndStoppedCuesHaveAudibleSamplesAndPredictableShortDuration() throws {
        for ascending in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try RecordingCueAudio.makeWave(ascending: ascending).write(to: url)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.08, accuracy: 0.001)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.35)
            XCTAssertLessThan(peak, 1)
            XCTAssertEqual(samples[0], 0)
            XCTAssertEqual(samples[Int(buffer.frameLength) - 1], 0)
        }
    }

    func testSoundCuesDefaultToOnAndFollowTheSavedPreference() throws {
        let suiteName = "TalkTextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(RecordingCuePreference.isEnabled(in: defaults))
        defaults.set(false, forKey: RecordingCuePreference.defaultsKey)
        XCTAssertFalse(RecordingCuePreference.isEnabled(in: defaults))
        defaults.set(true, forKey: RecordingCuePreference.defaultsKey)
        XCTAssertTrue(RecordingCuePreference.isEnabled(in: defaults))
    }

    func testDisabledReadyCueReturnsWithoutDelayingCapture() async {
        let player = SystemRecordingReadyCuePlayer(isEnabled: { false })
        let clock = ContinuousClock()
        let started = clock.now
        await player.play()
        XCTAssertLessThan(clock.now - started, .milliseconds(50))
    }

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
        let stoppedCue = EngineStoppedCueFake()
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let engine = makeEngine(recordingReadyCue: cue, recordingStoppedCue: stoppedCue, factory: factory)

        engine.startRecording()
        await waitUntil { cue.playCount == 1 }
        engine.stopRecording()
        await spinMainActor()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(cue.stopCount, 1)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertGreaterThanOrEqual(recorder.cancelCount, 1)
        XCTAssertEqual(stoppedCue.playCount, 0)
    }

    func testStopChimeWaitsForMicrophoneClosureAndPlaysOnlyOnce() async {
        let readyCue = EngineReadyCueFake()
        let stoppedCue = EngineStoppedCueFake()
        let recorder = EngineRecorderFake()
        recorder.immediateStopOutcome = nil
        stoppedCue.onPlay = { XCTAssertFalse(recorder.isRecording, "The stop cue must not enter the recording") }
        let engine = makeEngine(
            recordingReadyCue: readyCue, recordingStoppedCue: stoppedCue,
            factory: EngineRecorderFactoryFake(recorders: [recorder])
        )
        defer { engine.cleanup() }
        engine.startRecording()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(readyCue.playCount, 1)
        XCTAssertEqual(stoppedCue.playCount, 0)

        engine.stopRecording()
        engine.stopRecording()
        await waitUntil { recorder.stopCount == 1 }
        XCTAssertEqual(stoppedCue.playCount, 0)
        recorder.completeStop(with: .finished)
        await waitUntil { engine.state == .idle }
        engine.stopRecording()
        XCTAssertEqual(stoppedCue.playCount, 1)
    }

    func testAutomaticStopChimePlaysOnceEvenForSilentRecordings() async {
        for silent in [false, true] {
            let stoppedCue = EngineStoppedCueFake()
            let recorder = EngineRecorderFake()
            recorder.peakLevel = silent ? -.infinity : -12
            let factory = EngineRecorderFactoryFake(recorders: [recorder])
            let engine = makeEngine(recordingReadyCue: EngineReadyCueFake(), recordingStoppedCue: stoppedCue, factory: factory)
            engine.startRecording()
            await waitUntil { engine.state == .recording }
            // Automatic recorder events arrive after the input graph closes.
            recorder.isRecording = false
            factory.emit(.maximumDurationReached)
            await waitUntil { engine.state == (silent ? .failed : .idle) }
            factory.emit(.maximumDurationReached)
            XCTAssertEqual(stoppedCue.playCount, 1)
            engine.cleanup()
        }
    }

    private func makeEngine(
        recordingReadyCue: any RecordingReadyCuePlaying,
        recordingStoppedCue: any RecordingStoppedCuePlaying = EngineStoppedCueFake(),
        factory: EngineRecorderFactoryFake
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            permissionProvider: EnginePermissionFake(),
            recorderFactory: factory,
            recordingReadyCue: recordingReadyCue,
            recordingStoppedCue: recordingStoppedCue,
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
