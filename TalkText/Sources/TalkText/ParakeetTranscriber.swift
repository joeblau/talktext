@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// All weights remain resident; previews and final passes have independent
/// decoder state so cancellation cannot corrupt the next recording.
actor ParakeetTranscriber: SpeechTranscribing, TranscriptionPreflighting {
    private let resolver: any ParakeetModelResolving
    private let audioValidator: any AudioValidating
    private let recognizer: any ParakeetRecognizing
    private nonisolated let work = TranscriptionWorkRegistry()

    init(
        resolver: any ParakeetModelResolving = TalkTextDependencyResolver(),
        audioValidator: any AudioValidating = RecordedAudioValidator(),
        recognizer: any ParakeetRecognizing = FluidAudioParakeetRecognizer()
    ) {
        self.resolver = resolver
        self.audioValidator = audioValidator
        self.recognizer = recognizer
    }

    /// Call once at app startup, before any SDK logger or loader is constructed.
    static func configureRuntime() {
        ModelHub.offlineMode = true
        AppLogger.minimumLevel = .fault
        AppLogger.mirrorsToConsole = false
    }

    func preflightDependencies() async -> TalkTextDependencyPreflightResult {
        do {
            let preflight = try await prepareBackend()
            return .ready(preflight)
        } catch let failure as TalkTextDependencyPreflightFailure {
            return .failure(failure)
        } catch {
            return .failure(.modelLoadFailed(TranscriptionDiagnostic(error: error)))
        }
    }

    nonisolated func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        let task = Task { await self.performTranscription(audioURL: audioURL) }
        let identifier = work.register { task.cancel() }
        defer { work.remove(identifier) }
        return await withTaskCancellationHandler {
            if Task.isCancelled { task.cancel() }
            return await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated func cancelActiveTranscriptions() {
        work.cancelAll()
    }

    func makeLiveSession() async -> (any LiveSpeechSession)? {
        do {
            _ = try await prepareBackend()
            try Task.checkCancellation()
            return try await recognizer.makeLiveSession()
        } catch {
            // The final pass reports failures; a best-effort preview must not
            // interrupt capture or insert an error into the destination app.
            return nil
        }
    }

    private func performTranscription(audioURL: URL) async -> TranscriptionOutcome {
        do {
            try Task.checkCancellation()
            let validator = audioValidator
            let validation = await Task.detached(priority: .utility) { validator.validateAudio(at: audioURL) }.value
            if case let .invalid(failure) = validation { return .invalidAudio(failure) }
            _ = try await prepareBackend()
            try Task.checkCancellation()
            let result = try await recognizer.transcribe(audioURL: audioURL)
            try Task.checkCancellation()
            let text = TranscriptOutputClassifier.clean(result)
            return text.isEmpty ? .noSpeech : .success(text)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as TalkTextDependencyPreflightFailure {
            return Task.isCancelled ? .cancelled : .modelUnavailable(failure)
        } catch {
            return Task.isCancelled ? .cancelled : .inferenceFailed(TranscriptionDiagnostic(error: error))
        }
    }

    private func prepareBackend() async throws -> TalkTextDependencyPreflight {
        try await recognizer.validateHardware()
        let preflight: TalkTextDependencyPreflight
        switch resolver.preflight() {
        case let .failure(failure): throw failure
        case let .ready(value): preflight = value
        }
        do {
            try await recognizer.loadModels(at: preflight.model.url)
            return preflight
        } catch let failure as TalkTextDependencyPreflightFailure {
            throw failure
        } catch {
            throw TalkTextDependencyPreflightFailure.modelLoadFailed(TranscriptionDiagnostic(error: error))
        }
    }
}

protocol ParakeetRecognizing: Sendable {
    func validateHardware() async throws
    func loadModels(at directory: URL) async throws
    func transcribe(audioURL: URL) async throws -> String
    func makeLiveSession() async throws -> any LiveSpeechSession
}

extension ParakeetRecognizing {
    func validateHardware() async throws {}
}

private actor FluidAudioParakeetRecognizer: ParakeetRecognizing {
    private var models: AsrModels?
    private var modelURL: URL?
    private var loading: (url: URL, task: Task<AsrModels, Error>)?

    func validateHardware() async throws {
        // Core ML prediction crashes under Rosetta for these assets. Keep the
        // universal executable launchable, but require native Apple Silicon ASR.
        #if arch(x86_64)
            throw TalkTextDependencyPreflightFailure.unsupportedHardware
        #endif
    }

    func loadModels(at directory: URL) async throws {
        try await validateHardware()
        #if arch(arm64)
            if models != nil, modelURL == directory { return }
            if let pending = loading {
                let loaded = try await pending.task.value
                models = loaded
                modelURL = pending.url
                loading = nil
                if pending.url == directory { return }
            }
            let task = Task.detached(priority: .userInitiated) {
                let configuration = AsrModels.defaultConfiguration()
                return try AsrModels.loadLocal(from: directory, version: .v2, configuration: configuration)
            }
            loading = (directory, task)
            do {
                let loaded = try await task.value
                models = loaded
                modelURL = directory
                loading = nil
            } catch {
                loading = nil
                throw error
            }
        #endif
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let models else { throw ASRError.notInitialized }
        let manager = AsrManager(models: models)
        var decoder = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
        return try await manager.transcribe(audioURL, decoderState: &decoder).text
    }

    func makeLiveSession() async throws -> any LiveSpeechSession {
        guard let models else { throw ASRError.notInitialized }
        return try await ParakeetLiveSession(models: models)
    }
}

private final class TranscriptionWorkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    func register(_ cancel: @escaping @Sendable () -> Void) -> UUID {
        let identifier = UUID()
        lock.withLock { cancellations[identifier] = cancel }
        return identifier
    }

    func remove(_ identifier: UUID) {
        lock.withLock { _ = cancellations.removeValue(forKey: identifier) }
    }

    func cancelAll() {
        let pending = lock.withLock { Array(cancellations.values) }
        pending.forEach { $0() }
    }
}

private actor ParakeetLiveSession: LiveSpeechSession {
    private let manager: SlidingWindowAsrManager
    private var readPosition: AVAudioFramePosition = 0
    private var cancelled = false

    init(models: AsrModels) async throws {
        manager = SlidingWindowAsrManager(config: SlidingWindowAsrConfig(
            chunkSeconds: 1.5,
            hypothesisChunkSeconds: 1,
            leftContextSeconds: 2,
            rightContextSeconds: 0.25
        ))
        try await manager.loadModels(models)
        try await manager.startStreaming()
    }

    func transcribeNewAudio(at snapshotURL: URL) async -> String? {
        guard !cancelled, !Task.isCancelled else { return nil }
        do {
            // AVAudioFile handles the WAV layout. Seek past previously streamed
            // frames so a growing recording never repeats inference from zero.
            let file = try AVAudioFile(forReading: snapshotURL)
            guard file.length >= readPosition else { return nil }
            file.framePosition = readPosition
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard !cancelled,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else { return nil }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                await manager.streamAudio(buffer)
                readPosition = file.framePosition
            }
            return await manager.talkTextDraftTranscript()
        } catch {
            return nil
        }
    }

    func cancel() async {
        cancelled = true
        await manager.cancel()
    }
}

private extension SlidingWindowAsrManager {
    /// Read both tiers in one actor turn so promotion cannot duplicate or drop
    /// words between separate awaits.
    func talkTextDraftTranscript() -> String? {
        let text = [confirmedTranscript, volatileTranscript].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
