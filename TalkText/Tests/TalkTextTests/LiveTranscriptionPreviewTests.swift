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
        try preview.start(recordingURL: store.allocateRecordingURL(), interval: 0.1) { _ in
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
        preview.start(recordingURL: URL(fileURLWithPath: "/fixture.wav"), interval: 0.1) { drafts.append($0) }
        for _ in 0..<200 {
            if transcriber.callCount >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopped = preview.stop()
        await stopped?.value
        XCTAssertGreaterThanOrEqual(transcriber.callCount, 3)
        XCTAssertEqual(drafts, ["ask", "ask not"], "An unchanged draft must not retype text at the cursor")
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
