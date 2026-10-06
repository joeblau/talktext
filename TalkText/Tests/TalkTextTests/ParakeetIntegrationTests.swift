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
            // Exercise the same open-file snapshot path as microphone capture:
            // a draft must arrive from the first seconds, before the recorder stops.
            let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer {
                try? FileManager.default.removeItem(at: captureURL)
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            let source = try AVAudioFile(forReading: fixture)
            let capture = try CapturedAudioSink(file: AVAudioFile(forWriting: captureURL, settings: source.fileFormat.settings))
            XCTAssertTrue(capture.beginCapturing())
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 48000))
            try source.read(into: buffer)
            capture.append(buffer)
            let created = await ActiveWAVRecordingSnapshotter().createSnapshot(from: captureURL, at: snapshotURL)
            XCTAssertTrue(created, "Active input must be readable before the recorder stops")
            let start = ContinuousClock.now
            let draft = await transcriber.transcribe(audioURL: snapshotURL)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "A short draft must be fast enough to feel live")
            XCTAssertTrue(capture.close())
            guard case let .success(draftText) = draft else { return XCTFail("Expected a draft from the first three seconds") }
            XCTAssertTrue(draftText.lowercased().contains("fellow"))
        #endif
    }
}
