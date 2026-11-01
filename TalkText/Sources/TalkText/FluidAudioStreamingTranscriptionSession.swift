@preconcurrency import AVFoundation
import FluidAudio
import Foundation

final class FluidAudioStreamingTranscriptionSession: StreamingTranscriptionSession, @unchecked Sendable {
    private enum State {
        case active
        case finishing
        case finished
        case cancelled
    }

    private let manager: SlidingWindowAsrManager
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let feedTask: Task<Void, Never>
    private let updateTask: Task<Void, Never>
    private let lock = NSLock()
    private var state = State.active

    init(
        models: AsrModels,
        onUpdate: @escaping @MainActor (String) async -> Void
    ) async throws {
        let configuration = SlidingWindowAsrConfig(
            chunkSeconds: 0.32,
            hypothesisChunkSeconds: 0.32,
            leftContextSeconds: 2,
            rightContextSeconds: 0.24,
            minContextForConfirmation: 10,
            confirmationThreshold: 0.85
        )
        manager = SlidingWindowAsrManager(config: configuration)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .microphone)

        let (audioStream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        feedTask = Task { [manager] in
            for await buffer in audioStream {
                await manager.streamAudio(buffer)
            }
        }

        let updates = await manager.transcriptionUpdates
        updateTask = Task { [manager] in
            var lastText = ""
            for await _ in updates {
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                let text = [confirmed, volatile]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !text.isEmpty, text != lastText {
                    lastText = text
                    await onUpdate(text)
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(buffer)
    }

    func finish() async -> TranscriptionOutcome {
        guard transition(to: .finishing, from: .active) else { return .cancelled }
        continuation.finish()
        await feedTask.value
        do {
            let result = try await manager.finish()
            updateTask.cancel()
            lock.withLock { state = .finished }
            let text = TranscriptOutputClassifier.clean(result)
            return text.isEmpty ? .noSpeech : .success(text)
        } catch {
            updateTask.cancel()
            lock.withLock { state = .finished }
            return .inferenceFailed(TranscriptionDiagnostic(error: error))
        }
    }

    func cancel() async {
        let shouldCancel = lock.withLock {
            guard state == .active || state == .finishing else { return false }
            state = .cancelled
            return true
        }
        guard shouldCancel else { return }
        continuation.finish()
        feedTask.cancel()
        updateTask.cancel()
        await manager.cancel()
    }

    private func transition(to newState: State, from oldState: State) -> Bool {
        lock.withLock {
            guard state == oldState else { return false }
            state = newState
            return true
        }
    }
}

func finalTranscriptionOutcome(
    streamingSession: (any StreamingTranscriptionSession)?,
    audioURL: URL,
    transcriber: any SpeechTranscribing
) async -> TranscriptionOutcome {
    guard let streamingSession else {
        return await transcriber.transcribe(audioURL: audioURL)
    }
    let streamed = await streamingSession.finish()
    switch streamed {
    case .noSpeech, .inferenceFailed:
        return await transcriber.transcribe(audioURL: audioURL)
    default:
        return streamed
    }
}
