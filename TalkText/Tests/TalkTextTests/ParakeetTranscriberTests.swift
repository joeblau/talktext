import Foundation
import XCTest
@testable import TalkText

final class ParakeetTranscriberTests: XCTestCase {
    func testLiteralIdentifiersAndSymbolsSurviveFinalTranscription() async {
        let backend = ParakeetRecognizerFake(text: "  getUserByID != nil; [BLANK_AUDIO] \n")
        let result = await transcriber(backend: backend).transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav"))
        XCTAssertEqual(result, .success("getUserByID != nil; [BLANK_AUDIO]"))
    }

    func testSuccessfulEmptyOutputAloneMeansNoSpeech() async {
        let empty = await transcriber(backend: ParakeetRecognizerFake(text: " \n ")).transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav"))
        XCTAssertEqual(empty, .noSpeech)
        let failure = NSError(domain: "CoreML", code: 17, userInfo: [NSLocalizedDescriptionKey: "private dictated content"])
        let failed = await transcriber(backend: ParakeetRecognizerFake(error: failure)).transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav"))
        XCTAssertEqual(failed, .inferenceFailed(TranscriptionDiagnostic(domain: "CoreML", code: 17)))
    }

    func testInvalidAudioDoesNotLoadModelsOrInvokeInference() async {
        let backend = ParakeetRecognizerFake()
        let recognizer = transcriber(backend: backend, validation: .invalid(.unreadableFormat))
        let outcome = await recognizer.transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav"))
        XCTAssertEqual(outcome, .invalidAudio(.unreadableFormat))
        XCTAssertEqual(backend.loadCount, 0)
        XCTAssertEqual(backend.transcriptionCount, 0)
    }

    func testMissingWeightsFailBeforeInferenceAndNeverBecomeNoSpeech() async {
        let backend = ParakeetRecognizerFake()
        let failure = TalkTextDependencyPreflightFailure.missingModel(searchedPaths: [])
        let recognizer = ParakeetTranscriber(
            resolver: ParakeetResolverFake(result: .failure(failure)),
            audioValidator: ParakeetAudioValidatorFake(result: .valid(duration: 1)), recognizer: backend
        )
        let outcome = await recognizer.transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav"))
        XCTAssertEqual(outcome, .modelUnavailable(failure))
        XCTAssertEqual(backend.loadCount, 0)
    }

    func testModelLoadFailureHasSafeTypedDiagnostics() async {
        let backend = ParakeetRecognizerFake(loadError: NSError(domain: "CoreML", code: 9))
        let recognizer = transcriber(backend: backend)
        let preflight = await recognizer.preflightDependencies()
        let expected = TalkTextDependencyPreflightFailure.modelLoadFailed(TranscriptionDiagnostic(domain: "CoreML", code: 9))
        XCTAssertEqual(preflight, .failure(expected))
        let outcome = await recognizer.transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav"))
        XCTAssertEqual(outcome, .modelUnavailable(expected))
        XCTAssertEqual(backend.transcriptionCount, 0)
    }

    func testTaskCancellationAndApplicationTerminationCancelNativeWork() async throws {
        for terminateApplication in [false, true] {
            let backend = ParakeetRecognizerFake(block: true)
            let recognizer = transcriber(backend: backend)
            let operation = Task { await recognizer.transcribe(audioURL: URL(fileURLWithPath: "/fixture.wav")) }
            for _ in 0..<100 where backend.transcriptionCount == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(backend.transcriptionCount, 1)
            if terminateApplication { recognizer.cancelActiveTranscriptions() } else { operation.cancel() }
            let outcome = await operation.value
            XCTAssertEqual(outcome, .cancelled)
        }
    }

    private func transcriber(backend: ParakeetRecognizerFake, validation: AudioValidationResult = .valid(duration: 1)) -> ParakeetTranscriber {
        ParakeetTranscriber(
            resolver: ParakeetResolverFake(result: EngineFixtures.readyPreflightResult),
            audioValidator: ParakeetAudioValidatorFake(result: validation), recognizer: backend
        )
    }
}

private struct ParakeetResolverFake: ParakeetModelResolving {
    let result: TalkTextDependencyPreflightResult
    func preflight() -> TalkTextDependencyPreflightResult { result }
}

private struct ParakeetAudioValidatorFake: AudioValidating {
    let result: AudioValidationResult
    func validateAudio(at url: URL) -> AudioValidationResult { result }
}

private final class ParakeetRecognizerFake: ParakeetRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private var transcriptions = 0
    private let text: String
    private let error: NSError?
    private let loadError: NSError?
    private let block: Bool
    var loadCount: Int { lock.withLock { loads } }
    var transcriptionCount: Int { lock.withLock { transcriptions } }

    init(text: String = "hello", error: NSError? = nil, loadError: NSError? = nil, block: Bool = false) {
        self.text = text
        self.error = error
        self.loadError = loadError
        self.block = block
    }

    func loadModels(at directory: URL) async throws {
        lock.withLock { loads += 1 }
        if let loadError { throw loadError }
    }

    func transcribe(audioURL: URL) async throws -> String {
        lock.withLock { transcriptions += 1 }
        if block { try await Task.sleep(for: .seconds(10)) }
        if let error { throw error }
        return text
    }

    func makeLiveSession() async throws -> any LiveSpeechSession { throw CocoaError(.featureUnsupported) }
}
