import AVFoundation
import Foundation
import XCTest
@testable import TalkText

/// Opt in with TALKTEXT_PARAKEET_SMOKE_TEST=1 after installing verified weights.
/// Uses public fixture speech; never records the microphone or inserts text.
final class ParakeetIntegrationTests: XCTestCase {
    func testIntelPreflightRejectsUnsupportedHardwareBeforeLoadingModels() async throws {
        #if arch(x86_64)
            let result = await ParakeetTranscriber().preflightDependencies()
            XCTAssertEqual(result, .failure(.unsupportedHardware))
        #else
            throw XCTSkip("Intel guard is exercised in the Intel CI job")
        #endif
    }

    func testPinnedModelsTranscribeKnownSpeechAndProduceLiveDrafts() async throws {
        #if arch(x86_64)
            throw XCTSkip("Parakeet inference requires native Apple Silicon")
        #else
            let environment = ProcessInfo.processInfo.environment
            guard environment["TALKTEXT_PARAKEET_SMOKE_TEST"] == "1" else {
                throw XCTSkip("Real Parakeet inference is enabled in the native backend CI matrix")
            }
            ParakeetTranscriber.configureRuntime()
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let fixture = environment["TALKTEXT_TEST_AUDIO"].map { URL(fileURLWithPath: $0) }
                ?? package.deletingLastPathComponent().appendingPathComponent("tests/fixtures/jfk.wav")
            let transcriber = ParakeetTranscriber()
            let ready = await transcriber.preflightDependencies()
            guard case .ready = ready else { return XCTFail("Pinned Parakeet models failed to load: \(ready)") }
            let final = await transcriber.transcribe(audioURL: fixture)
            guard case let .success(text) = final else { return XCTFail("Expected a successful native transcription") }
            XCTAssertTrue(text.lowercased().contains("country"))
            XCTAssertTrue(text.lowercased().contains("ask not"))
            guard let session = await transcriber.makeLiveSession() else { return XCTFail("Expected a native live session") }
            // Exercise the same open-file snapshot path as microphone capture,
            // with short increments rather than feeding a finished WAV at once.
            let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer {
                try? FileManager.default.removeItem(at: captureURL)
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            let source = try AVAudioFile(forReading: fixture)
            let capture = try CapturedAudioSink(file: AVAudioFile(forWriting: captureURL, settings: source.fileFormat.settings))
            XCTAssertTrue(capture.beginCapturing())
            let snapshotter = ActiveWAVRecordingSnapshotter()
            for _ in 0..<6 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8000))
                try source.read(into: buffer)
                capture.append(buffer)
                let created = await snapshotter.createSnapshot(from: captureURL, at: snapshotURL)
                XCTAssertTrue(created, "Active input must be readable before the recorder stops")
                _ = await session.transcribeNewAudio(at: snapshotURL)
                try await Task.sleep(for: .milliseconds(50))
            }
            var earlyDraft: String?
            for _ in 0..<100 {
                earlyDraft = await session.transcribeNewAudio(at: snapshotURL)
                if earlyDraft?.isEmpty == false { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertFalse(earlyDraft?.isEmpty ?? true, "The first three seconds must produce a draft before stop")
            XCTAssertTrue(capture.close())
            var draft: String?
            for _ in 0..<100 {
                draft = await session.transcribeNewAudio(at: fixture)
                if draft?.lowercased().contains("country") == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            async let cancellation: Void = session.cancel()
            let independentFinal = await transcriber.transcribe(audioURL: fixture)
            await cancellation
            guard case let .success(independentText) = independentFinal else { return XCTFail("Final inference must survive preview cancellation") }
            XCTAssertTrue(independentText.lowercased().contains("ask not"))
            XCTAssertFalse(draft?.isEmpty ?? true, "Expected a draft from the incremental recognizer")
            let afterCancel = await session.transcribeNewAudio(at: fixture)
            XCTAssertNil(afterCancel, "Cancelled sessions must not deliver stale drafts")
        #endif
    }
}
