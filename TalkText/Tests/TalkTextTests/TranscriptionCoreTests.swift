import Foundation
import XCTest
@testable import TalkText

final class TranscriptionCoreTests: XCTestCase {
    func testSuccessfulBlankAudioOutputIsClassifiedAsNoSpeech() async {
        let diagnostic = ProcessDiagnostic(
            terminationStatus: 0,
            terminationReason: .exit,
            standardOutput: Data("  [BLANK_AUDIO]\n(blank audio)  ".utf8),
            standardError: Data("backend metadata".utf8)
        )
        let transcriber = makeTranscriber(processResult: .completed(diagnostic))

        let outcome = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(outcome, .noSpeech)
    }

    func testSuccessfulOutputIsCleanedWithoutLosingDictatedText() async {
        let diagnostic = ProcessDiagnostic(
            terminationStatus: 0,
            terminationReason: .exit,
            standardOutput: Data("\n  A private sentence. [BLANK_AUDIO] \n".utf8)
        )
        let transcriber = makeTranscriber(processResult: .completed(diagnostic))

        let outcome = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(outcome, .success("A private sentence."))
    }

    func testEmptyOutputFromNonzeroExitIsFailureNotNoSpeech() async {
        let diagnostic = ProcessDiagnostic(
            terminationStatus: 17,
            terminationReason: .exit,
            standardError: Data("failure detail".utf8)
        )
        let transcriber = makeTranscriber(processResult: .completed(diagnostic))

        let outcome = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(outcome, .processFailed(diagnostic))
    }

    func testSignalTerminationIsProcessFailureWithDiagnostic() async {
        let diagnostic = ProcessDiagnostic(
            terminationStatus: SIGTERM,
            terminationReason: .uncaughtSignal,
            standardError: Data("terminated".utf8)
        )
        let transcriber = makeTranscriber(processResult: .completed(diagnostic))

        let outcome = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(outcome, .processFailed(diagnostic))
    }

    func testLaunchTimeoutAndCancellationRemainDistinctTypedOutcomes() async {
        let launchDiagnostic = ProcessDiagnostic(
            launchErrorDomain: NSPOSIXErrorDomain,
            launchErrorCode: Int(ENOENT),
            launchErrorDescription: "not found"
        )
        let timeoutDiagnostic = ProcessDiagnostic(
            terminationStatus: SIGKILL,
            terminationReason: .uncaughtSignal
        )
        let cancellationDiagnostic = ProcessDiagnostic(
            terminationStatus: SIGTERM,
            terminationReason: .uncaughtSignal
        )

        let launch = await makeTranscriber(processResult: .launchFailed(launchDiagnostic))
            .transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))
        let timeout = await makeTranscriber(processResult: .timedOut(timeoutDiagnostic))
            .transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))
        let cancellation = await makeTranscriber(processResult: .cancelled(cancellationDiagnostic))
            .transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(launch, .launchFailed(launchDiagnostic))
        XCTAssertEqual(timeout, .timedOut(timeoutDiagnostic))
        XCTAssertEqual(cancellation, .cancelled(cancellationDiagnostic))
    }

    func testMissingDependenciesRemainDistinct() async {
        let runner = CoreStubProcessRunner(result: .completed(successDiagnostic("unused")))
        let audioURL = URL(fileURLWithPath: "/tmp/audio.wav")
        let missingBinary = WhisperTranscriber(
            dependencyResolver: CoreStubDependencyResolver(result: .missing(.binary)),
            audioValidator: CoreStubAudioValidator(result: .valid(duration: 1)),
            processRunner: runner
        )
        let missingModel = WhisperTranscriber(
            dependencyResolver: CoreStubDependencyResolver(result: .missing(.model)),
            audioValidator: CoreStubAudioValidator(result: .valid(duration: 1)),
            processRunner: runner
        )

        let binaryOutcome = await missingBinary.transcribe(audioURL: audioURL)
        let modelOutcome = await missingModel.transcribe(audioURL: audioURL)

        XCTAssertEqual(binaryOutcome, .missingDependency(.binary))
        XCTAssertEqual(modelOutcome, .missingDependency(.model))
        XCTAssertEqual(runner.invocationCount, 0)
    }

    func testInvalidAudioStopsBeforeProcessLaunch() async {
        let runner = CoreStubProcessRunner(result: .completed(successDiagnostic("unused")))
        let transcriber = WhisperTranscriber(
            dependencyResolver: resolvedDependencies(),
            audioValidator: CoreStubAudioValidator(result: .invalid(.unreadableFormat)),
            processRunner: runner
        )

        let outcome = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        XCTAssertEqual(outcome, .invalidAudio(.unreadableFormat))
        XCTAssertEqual(runner.invocationCount, 0)
    }

    func testRecordedAudioValidatorChecksExistenceSizeFormatAndUsefulDuration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-AudioValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingURL = root.appendingPathComponent("missing.wav")
        let emptyURL = root.appendingPathComponent("empty.wav")
        let corruptURL = root.appendingPathComponent("corrupt.wav")
        let shortURL = root.appendingPathComponent("short.wav")
        let validURL = root.appendingPathComponent("valid.wav")
        let longURL = root.appendingPathComponent("long.wav")
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        try Data("not audio".utf8).write(to: corruptURL)
        try writeSilentWAV(to: shortURL, duration: 0.02)
        try writeSilentWAV(to: validURL, duration: 0.12)
        try writeSilentWAV(to: longURL, duration: 0.3)

        let validator = RecordedAudioValidator(
            minimumUsefulDuration: 0.05,
            maximumUsefulDuration: 0.2
        )

        XCTAssertEqual(validator.validateAudio(at: missingURL), .invalid(.missing))
        XCTAssertEqual(validator.validateAudio(at: emptyURL), .invalid(.empty))
        XCTAssertEqual(validator.validateAudio(at: corruptURL), .invalid(.unreadableFormat))
        guard case .invalid(.tooShort) = validator.validateAudio(at: shortURL) else {
            return XCTFail("Expected short audio rejection")
        }
        guard case let .valid(duration) = validator.validateAudio(at: validURL) else {
            return XCTFail("Expected valid audio")
        }
        XCTAssertEqual(duration, 0.12, accuracy: 0.01)
        guard case .invalid(.tooLong) = validator.validateAudio(at: longURL) else {
            return XCTFail("Expected long audio rejection")
        }
    }

    func testTranscriptClassifierTreatsBlankMarkersCaseInsensitively() {
        XCTAssertEqual(
            TranscriptOutputClassifier.clean(" [blank_audio] (BLANK AUDIO) "),
            ""
        )
    }

    private func makeTranscriber(processResult: ProcessRunResult) -> WhisperTranscriber {
        WhisperTranscriber(
            dependencyResolver: resolvedDependencies(),
            audioValidator: CoreStubAudioValidator(result: .valid(duration: 1)),
            processRunner: CoreStubProcessRunner(result: processResult),
            timeout: 1
        )
    }

    private func resolvedDependencies() -> CoreStubDependencyResolver {
        CoreStubDependencyResolver(
            result: .resolved(
                ResolvedWhisperDependencies(
                    binaryURL: URL(fileURLWithPath: "/fixture/whisper-cli"),
                    modelURL: URL(fileURLWithPath: "/fixture/model.bin")
                )
            )
        )
    }

    private func successDiagnostic(_ output: String) -> ProcessDiagnostic {
        ProcessDiagnostic(
            terminationStatus: 0,
            terminationReason: .exit,
            standardOutput: Data(output.utf8)
        )
    }

    private func writeSilentWAV(to url: URL, duration: TimeInterval) throws {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount = UInt32(duration * Double(sampleRate))
        let blockAlign = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let audioByteCount = frameCount * UInt32(blockAlign)

        var data = Data("RIFF".utf8)
        appendLittleEndian(36 + audioByteCount, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(audioByteCount, to: &data)
        data.append(Data(repeating: 0, count: Int(audioByteCount)))
        try data.write(to: url)
    }

    private func appendLittleEndian(_ value: some FixedWidthInteger, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private struct CoreStubDependencyResolver: WhisperDependencyResolving {
    let result: WhisperDependencyResolution

    func resolveDependencies() -> WhisperDependencyResolution {
        result
    }
}

private struct CoreStubAudioValidator: AudioValidating {
    let result: AudioValidationResult

    func validateAudio(at url: URL) -> AudioValidationResult {
        result
    }
}

private final class CoreStubProcessRunner: AsyncProcessRunning, @unchecked Sendable {
    let result: ProcessRunResult
    private let lock = NSLock()
    private var _invocationCount = 0

    init(result: ProcessRunResult) {
        self.result = result
    }

    var invocationCount: Int {
        lock.withLock { _invocationCount }
    }

    func run(_ command: ProcessCommand, timeout: TimeInterval) async -> ProcessRunResult {
        lock.withLock { _invocationCount += 1 }
        return result
    }
}
