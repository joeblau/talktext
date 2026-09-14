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

    func testStopClosesMicrophoneBeforeWaitingForPreview() async throws {
        let recorder = EngineRecorderFake()
        let snapshotter = EngineGatedSnapshotter()
        let engine = TranscriptionEngine(
            permissionProvider: EnginePermissionFake(),
            recorderFactory: EngineRecorderFactoryFake(recorders: [recorder]),
            recordingReadyCue: EngineReadyCueFake(),
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
        XCTAssertEqual(engine.state, .stopping)
        await snapshotter.complete()
        for _ in 0..<1_000 {
            if engine.state == .idle { break }
            await Task.yield()
        }
        XCTAssertEqual(engine.state, .idle)
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
