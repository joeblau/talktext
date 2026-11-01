import AVFoundation
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class StreamingTranscriptionTests: XCTestCase {
    func testStreamProvidesDraftAndFinalWithoutSnapshotsOrBatchInference() async throws {
        let session = StreamingSessionFake(outcome: .success("stream final"))
        let transcriber = StreamingTranscriberFake(session: session)
        let delivery = EngineDeliveryFake()
        let snapshotter = EngineSnapshotterFake()
        let engine = makeEngine(
            transcriber: transcriber,
            delivery: delivery,
            snapshotter: snapshotter
        )
        defer { engine.cleanup() }

        engine.startRecording()
        await waitUntil { engine.state == .recording }
        await session.emit("stream draft")
        await waitUntil { delivery.liveUpdatedTexts.last == "stream draft" }

        XCTAssertEqual(delivery.liveUpdatedTexts.first, "")
        XCTAssertGreaterThan(delivery.liveUpdatedTexts.count, 2, "The draft should appear progressively")
        XCTAssertTrue(delivery.liveUpdatedTexts.dropFirst().allSatisfy { "stream draft".hasPrefix($0) })

        engine.stopRecording()
        await waitUntil { engine.state == .idle }

        XCTAssertEqual(delivery.finalizedTexts, ["stream final"])
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(transcriber.batchCount, 0)
        XCTAssertTrue(snapshotter.requests.isEmpty)
    }

    func testFinalizationDoesNotWaitForTypewriterAnimation() async {
        let session = StreamingSessionFake(outcome: .success("short final"))
        let transcriber = StreamingTranscriberFake(session: session)
        let delivery = EngineDeliveryFake()
        let engine = makeEngine(transcriber: transcriber, delivery: delivery)
        defer { engine.cleanup() }
        engine.startRecording()
        await waitUntil { engine.state == .recording }
        await session.emit("a much longer draft that should not finish animating")

        engine.stopRecording()
        await waitUntil { engine.state == .idle }

        XCTAssertEqual(delivery.finalizedTexts, ["short final"])
        XCTAssertNotEqual(delivery.liveUpdatedTexts.last, "a much longer draft that should not finish animating")
    }

    func testEmptyOrFailedStreamFallsBackToCompleteRecording() async {
        for streamedOutcome in [
            TranscriptionOutcome.noSpeech,
            .inferenceFailed(TranscriptionDiagnostic(domain: "CoreML", code: 1)),
        ] {
            let session = StreamingSessionFake(outcome: streamedOutcome)
            let transcriber = StreamingTranscriberFake(session: session, batchOutcome: .success("batch final"))
            let delivery = EngineDeliveryFake()
            let engine = makeEngine(transcriber: transcriber, delivery: delivery)
            engine.startRecording()
            await waitUntil { engine.state == .recording }
            engine.stopRecording()
            await waitUntil { engine.state == .idle }

            XCTAssertEqual(delivery.finalizedTexts, ["batch final"])
            XCTAssertEqual(transcriber.batchCount, 1)
            engine.cleanup()
        }
    }

    func testCancellingRecordingCancelsStreamWithoutStartingBatchInference() async {
        let session = StreamingSessionFake(outcome: .success("unused"))
        let transcriber = StreamingTranscriberFake(session: session)
        let engine = makeEngine(transcriber: transcriber)
        defer { engine.cleanup() }
        engine.startRecording()
        await waitUntil { engine.state == .recording }

        engine.cancelCurrentOperation()
        await waitUntil { session.cancelCount == 1 }

        XCTAssertEqual(engine.state, .failed)
        XCTAssertEqual(session.finishCount, 0)
        XCTAssertEqual(transcriber.batchCount, 0)
    }

    private func makeEngine(
        transcriber: StreamingTranscriberFake,
        delivery: EngineDeliveryFake = EngineDeliveryFake(),
        snapshotter: EngineSnapshotterFake = EngineSnapshotterFake()
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            permissionProvider: EnginePermissionFake(),
            recorderFactory: EngineRecorderFactoryFake(),
            recordingReadyCue: EngineReadyCueFake(),
            recordingStoppedCue: EngineStoppedCueFake(),
            recordingFileStore: EngineFileStoreFake(),
            recordingSnapshotter: snapshotter,
            dependencyPreflight: EnginePreflightFake(),
            transcriber: transcriber,
            textDelivery: delivery,
            livePreviewInterval: 0.1,
            performStartupCleanup: false
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for streaming engine state")
    }
}

private final class StreamingTranscriberFake: SpeechTranscribing, @unchecked Sendable {
    private let session: StreamingSessionFake
    private let batchOutcome: TranscriptionOutcome
    private let lock = NSLock()
    private var batches = 0

    var batchCount: Int { lock.withLock { batches } }

    init(session: StreamingSessionFake, batchOutcome: TranscriptionOutcome = .noSpeech) {
        self.session = session
        self.batchOutcome = batchOutcome
    }

    func startStreamingTranscription(
        onUpdate: @escaping @MainActor (String) async -> Void
    ) async -> (any StreamingTranscriptionSession)? {
        session.onUpdate = onUpdate
        return session
    }

    func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        lock.withLock { batches += 1 }
        return batchOutcome
    }
}

private final class StreamingSessionFake: StreamingTranscriptionSession, @unchecked Sendable {
    private let outcome: TranscriptionOutcome
    private let lock = NSLock()
    private var finishes = 0
    private var cancels = 0
    var onUpdate: (@MainActor (String) async -> Void)?

    var finishCount: Int { lock.withLock { finishes } }
    var cancelCount: Int { lock.withLock { cancels } }

    init(outcome: TranscriptionOutcome) {
        self.outcome = outcome
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async -> TranscriptionOutcome {
        lock.withLock { finishes += 1 }
        return outcome
    }

    func cancel() async {
        lock.withLock { cancels += 1 }
    }

    func emit(_ text: String) async {
        await onUpdate?(text)
    }
}
