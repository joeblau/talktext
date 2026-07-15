import Foundation
@testable import TalkText

final class EnginePreflightFake: WhisperDependencyPreflighting, @unchecked Sendable {
    private let lock = NSLock()
    private var result: TalkTextDependencyPreflightResult?
    private var continuation: CheckedContinuation<TalkTextDependencyPreflightResult, Never>?
    private(set) var invocationCount = 0

    init(result: TalkTextDependencyPreflightResult? = EngineFixtures.readyPreflightResult) {
        self.result = result
    }

    func preflightDependencies() async -> TalkTextDependencyPreflightResult {
        let immediateResult = lock.withLock { () -> TalkTextDependencyPreflightResult? in
            invocationCount += 1
            return result
        }
        if let immediateResult {
            return immediateResult
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: TalkTextDependencyPreflightResult) {
        let continuation: CheckedContinuation<TalkTextDependencyPreflightResult, Never>?
        lock.lock()
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

@MainActor
final class EnginePermissionFake: MicrophonePermissionProviding {
    var status: MicrophoneAuthorization
    private(set) var statusCallCount = 0
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    init(status: MicrophoneAuthorization = .authorized) {
        self.status = status
    }

    func authorizationStatus() -> MicrophoneAuthorization {
        statusCallCount += 1
        return status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolveAccess(granted: Bool) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: granted)
    }
}

@MainActor
final class EngineRecorderFake: AudioRecording {
    var isRecording = false
    var startResult = true
    var immediateStopOutcome: RecorderStopOutcome? = .finished
    var onStart: (() -> Void)?
    private(set) var maximumDurations: [TimeInterval] = []
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private var stopContinuation: CheckedContinuation<RecorderStopOutcome, Never>?

    func start(maximumDuration: TimeInterval) -> Bool {
        maximumDurations.append(maximumDuration)
        isRecording = startResult
        onStart?()
        return startResult
    }

    func stop() async -> RecorderStopOutcome {
        stopCount += 1
        isRecording = false
        if let immediateStopOutcome {
            return immediateStopOutcome
        }
        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func completeStop(with outcome: RecorderStopOutcome) {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(returning: outcome)
    }

    func cancel() {
        cancelCount += 1
        isRecording = false
        completeStop(with: .cancelled)
    }
}

@MainActor
final class EngineRecorderFactoryFake: AudioRecorderCreating {
    var recorders: [EngineRecorderFake]
    var creationError: (any Error)?
    private(set) var creationCount = 0
    private(set) var eventHandlers: [@MainActor (RecorderEvent) -> Void] = []

    init(recorders: [EngineRecorderFake] = [EngineRecorderFake()]) {
        self.recorders = recorders
    }

    func makeRecorder(
        at url: URL,
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws -> any AudioRecording {
        creationCount += 1
        if let creationError {
            throw creationError
        }
        guard !recorders.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        let recorder = recorders.removeFirst()
        eventHandlers.append(eventHandler)
        return recorder
    }

    func emit(_ event: RecorderEvent, recorderIndex: Int = 0) {
        guard eventHandlers.indices.contains(recorderIndex) else {
            return
        }
        eventHandlers[recorderIndex](event)
    }
}

@MainActor
final class EngineFileStoreFake: RecordingFileStoring {
    private(set) var allocatedURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    private(set) var staleCleanupCount = 0
    private(set) var instanceCleanupCount = 0
    var allocationError: (any Error)?
    var removalError: (any Error)?

    func allocateRecordingURL() throws -> URL {
        if let allocationError {
            throw allocationError
        }
        let url = URL(fileURLWithPath: "/tmp/engine-recording-\(UUID().uuidString).wav")
        allocatedURLs.append(url)
        return url
    }

    func removeRecording(at url: URL) throws {
        removedURLs.append(url)
        if let removalError {
            throw removalError
        }
    }

    func removeStaleOwnedFiles(olderThan age: TimeInterval) throws {
        staleCleanupCount += 1
    }

    func cleanupInstance() throws {
        instanceCleanupCount += 1
    }
}

final class EngineTranscriberFake: WhisperTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: TranscriptionOutcome?
    private var continuation: CheckedContinuation<TranscriptionOutcome, Never>?
    private var cancelled = false
    private(set) var invocationCount = 0
    private(set) var synchronousTerminationCount = 0

    init(outcome: TranscriptionOutcome? = .noSpeech) {
        self.outcome = outcome
    }

    func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        let immediateOutcome = lock.withLock { () -> TranscriptionOutcome? in
            invocationCount += 1
            return outcome
        }
        if let immediateOutcome {
            return immediateOutcome
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled(EngineFixtures.emptyDiagnostic))
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.resolveCancellation()
        }
    }

    func resolve(_ outcome: TranscriptionOutcome) {
        let continuation: CheckedContinuation<TranscriptionOutcome, Never>?
        lock.lock()
        self.outcome = outcome
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    func terminateActiveTranscriptions() {
        lock.lock()
        synchronousTerminationCount += 1
        lock.unlock()
        resolveCancellation()
    }

    private func resolveCancellation() {
        let continuation: CheckedContinuation<TranscriptionOutcome, Never>?
        lock.lock()
        cancelled = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: .cancelled(EngineFixtures.emptyDiagnostic))
    }
}

@MainActor
final class EngineDeliveryFake: TextDelivering {
    var capturedTarget: PasteTarget?
    var outcome: DeliveryOutcome?
    private(set) var captureCount = 0
    private(set) var deliveredTexts: [String] = []
    private(set) var deliveredTargets: [PasteTarget?] = []
    private var continuation: CheckedContinuation<DeliveryOutcome, Never>?

    init(outcome: DeliveryOutcome? = .inserted) {
        self.outcome = outcome
    }

    func captureCurrentTarget(excludingBundleIdentifier: String?) -> PasteTarget? {
        captureCount += 1
        return capturedTarget
    }

    func deliver(_ text: String, to target: PasteTarget?) async -> DeliveryOutcome {
        deliveredTexts.append(text)
        deliveredTargets.append(target)
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ outcome: DeliveryOutcome) {
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

enum EngineFixtures {
    static let emptyDiagnostic = ProcessDiagnostic(
        terminationStatus: 0,
        terminationReason: .exit
    )

    static let readyPreflightResult: TalkTextDependencyPreflightResult = {
        let binary = URL(fileURLWithPath: "/fixture/whisper-cli")
        let model = URL(fileURLWithPath: "/fixture/model.bin")
        return .ready(
            TalkTextDependencyPreflight(
                dependencies: ResolvedWhisperDependencies(binaryURL: binary, modelURL: model),
                backend: WhisperBackendDiagnostic(
                    executable: ResolvedDependencyPath(url: binary, source: .bundled),
                    version: WhisperBackendContract.supportedVersions[0],
                    compatibility: "test-verified"
                ),
                model: ResolvedDependencyPath(url: model, source: .bundled)
            )
        )
    }()
}
