@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class LiveTranscriptionPreviewTests: XCTestCase {
    func testCleanupRemovesSnapshotThatFinishesWritingAfterCancellation() async throws {
        let store = try TemporaryRecordingFileStore()
        defer { try? store.cleanupInstance() }
        let snapshotter = EngineGatedSnapshotter()
        let transcriber = EngineTranscriberFake()
        let preview = LiveTranscriptionPreview(
            recordingFileStore: store, recordingSnapshotter: snapshotter, transcriber: transcriber
        )
        try preview.start(recordingURL: store.allocateRecordingURL(), minimumInterval: 0.1) { _ in
            XCTFail("A cancelled preview must not deliver text")
        }
        let destination = try await waitForSnapshot(snapshotter)
        let task = preview.stop()
        preview.cleanup()
        await snapshotter.complete()
        await task?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(transcriber.invocationCount, 0)
    }

    func testStopClosesMicrophoneAndStartsFinalTranscriptionWithoutWaitingForPreview() async throws {
        let recorder = EngineRecorderFake()
        let stoppedCue = EngineStoppedCueFake()
        let snapshotter = EngineGatedSnapshotter()
        let engine = TranscriptionEngine(
            permissionProvider: EnginePermissionFake(),
            recorderFactory: EngineRecorderFactoryFake(recorders: [recorder]),
            recordingReadyCue: EngineReadyCueFake(),
            recordingStoppedCue: stoppedCue,
            recordingFileStore: EngineFileStoreFake(),
            recordingSnapshotter: snapshotter,
            dependencyPreflight: EnginePreflightFake(),
            transcriber: EngineTranscriberFake(),
            textDelivery: EngineDeliveryFake(),
            livePreviewInterval: 0.1,
            performStartupCleanup: false
        )
        defer { engine.cleanup() }
        engine.startRecording()
        let destination = try await waitForSnapshot(snapshotter)
        defer { try? FileManager.default.removeItem(at: destination) }
        engine.stopRecording()
        for _ in 0..<1_000 {
            if recorder.stopCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(stoppedCue.playCount, 1, "Stop audio feedback must not wait for preview inference")
        for _ in 0..<1_000 {
            if engine.state == .idle { break }
            await Task.yield()
        }
        XCTAssertEqual(engine.state, .idle)
        await snapshotter.complete()
    }

    func testEachDraftIsAFullPassAndRepeatsAreNotRedelivered() async throws {
        let transcriber = PreviewTranscriberFake(drafts: ["ask", "ask not", "ask not"])
        let preview = LiveTranscriptionPreview(
            recordingFileStore: EngineFileStoreFake(),
            recordingSnapshotter: EngineSnapshotterFake(result: true), transcriber: transcriber
        )
        var drafts: [String] = []
        preview.start(recordingURL: URL(fileURLWithPath: "/fixture.wav"), minimumInterval: 0.1) { drafts.append($0) }
        for _ in 0..<200 {
            if transcriber.callCount >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopped = preview.stop()
        await stopped?.value
        XCTAssertGreaterThanOrEqual(transcriber.callCount, 3)
        XCTAssertEqual(drafts, ["ask", "ask not"], "An unchanged draft must not retype text at the cursor")
    }

    func testLongDictationLocksEarlierSpeechAtAPauseAndFinalizesOnlyTheRest() async throws {
        let store = try TemporaryRecordingFileStore()
        defer { try? store.cleanupInstance() }
        // 40 s of speech-level tone with one short pause at 20 s.
        let recordingURL = try store.allocateRecordingURL()
        try writeTone(to: recordingURL, seconds: 40, silences: [20.0..<20.4])
        let transcriber = DurationTranscriberFake()
        let preview = LiveTranscriptionPreview(
            recordingFileStore: store, recordingSnapshotter: CopyingSnapshotter(), transcriber: transcriber
        )
        var drafts: [String] = []
        preview.start(recordingURL: recordingURL, minimumInterval: 0.05) { drafts.append($0) }
        for _ in 0..<500 where drafts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await preview.stop()?.value

        XCTAssertEqual(drafts, ["20.2 19.8"], "The draft is locked text through the pause plus the rest")
        XCTAssertTrue(
            transcriber.durations.allSatisfy { $0 <= 30 },
            "No pass may re-transcribe more than the window: \(transcriber.durations)"
        )

        let final = await preview.finalTranscription(recordingURL: recordingURL)
        XCTAssertEqual(final, .success("20.2 19.8"))
        XCTAssertEqual(transcriber.durations.last, 19.8, "The final pass covers only audio after the locked text")
        XCTAssertFalse(transcriber.urls.contains(recordingURL))
        preview.cleanup()
    }

    func testShortDictationFinalizesWithOnePassOverTheWholeRecording() async throws {
        let store = try TemporaryRecordingFileStore()
        defer { try? store.cleanupInstance() }
        let recordingURL = try store.allocateRecordingURL()
        try writeTone(to: recordingURL, seconds: 10, silences: [])
        let transcriber = DurationTranscriberFake()
        let preview = LiveTranscriptionPreview(
            recordingFileStore: store, recordingSnapshotter: CopyingSnapshotter(), transcriber: transcriber
        )
        var drafts: [String] = []
        preview.start(recordingURL: recordingURL, minimumInterval: 0.05) { drafts.append($0) }
        for _ in 0..<500 where drafts.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await preview.stop()?.value

        let final = await preview.finalTranscription(recordingURL: recordingURL)
        XCTAssertEqual(drafts, ["10.0"])
        XCTAssertEqual(final, .success("10.0"))
        XCTAssertEqual(transcriber.urls.last, recordingURL)
        preview.cleanup()
    }

    func testAudioWindowFindsThePauseAndCopiesExactFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try writeTone(to: source, seconds: 5, silences: [3.0..<3.2])

        let layout = try XCTUnwrap(RecordingAudioWindow.layout(of: source))
        XCTAssertEqual(layout, RecordingAudioWindow.Layout(frameCount: 80_000, sampleRate: 16_000))
        let pause = try XCTUnwrap(RecordingAudioWindow.quietestFrame(in: source, searching: 16_000..<64_000))
        XCTAssertTrue((48_000..<51_200).contains(pause), "Expected the cut inside the pause, got \(pause)")

        // A single quiet step that is not at the start of the search must still win.
        let click = directory.appendingPathComponent("click.wav")
        try writeTone(to: click, seconds: 2, silences: [1.5..<1.52])
        let shortPause = try XCTUnwrap(RecordingAudioWindow.quietestFrame(in: click, searching: 0..<32_000))
        XCTAssertTrue((23_840..<24_480).contains(shortPause), "Expected the cut at the 20 ms gap, got \(shortPause)")

        let segment = directory.appendingPathComponent("segment.wav")
        XCTAssertTrue(RecordingAudioWindow.write(from: source, frames: 16_000..<pause, to: segment))
        XCTAssertEqual(RecordingAudioWindow.layout(of: segment)?.frameCount, pause - 16_000)
        XCTAssertFalse(RecordingAudioWindow.write(from: source, frames: 0..<90_000, to: segment))
    }

    /// 16 kHz mono 16-bit PCM, matching the recorder's file format.
    private func writeTone(to url: URL, seconds: Double, silences: [Range<Double>]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frames {
            let time = Double(index) / 16_000
            let silent = silences.contains { $0.contains(time) }
            samples[index] = silent ? 0 : Float(0.3 * sin(2 * .pi * 220 * time))
        }
        try file.write(from: buffer)
    }

    private func waitForSnapshot(_ snapshotter: EngineGatedSnapshotter) async throws -> URL {
        for _ in 0..<200 {
            if let destination = await snapshotter.destination { return destination }
            try await Task.sleep(for: .milliseconds(10))
        }
        await snapshotter.complete()
        throw CocoaError(.fileReadNoSuchFile)
    }
}

private final class PreviewTranscriberFake: SpeechTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String]
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    init(drafts: [String]) { self.drafts = drafts }
    func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        lock.withLock {
            calls += 1
            return drafts.isEmpty ? .noSpeech : .success(drafts.removeFirst())
        }
    }
}

/// Copies the finished fixture as a recorder snapshot would.
private struct CopyingSnapshotter: ActiveRecordingSnapshotting {
    func createSnapshot(from sourceURL: URL, at destinationURL: URL) async -> Bool {
        (try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)) != nil
    }
}

/// Answers with the duration of the audio it was given, to one decimal.
private final class DurationTranscriberFake: SpeechTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(url: URL, duration: Double)] = []
    var urls: [URL] { lock.withLock { calls.map(\.url) } }
    var durations: [Double] { lock.withLock { calls.map(\.duration) } }

    func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        guard let layout = RecordingAudioWindow.layout(of: audioURL) else { return .noSpeech }
        let duration = (Double(layout.frameCount) / layout.sampleRate * 10).rounded() / 10
        lock.withLock { calls.append((audioURL, duration)) }
        return .success(String(format: "%.1f", duration))
    }
}
