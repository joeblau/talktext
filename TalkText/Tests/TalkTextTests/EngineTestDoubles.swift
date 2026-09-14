import Foundation
@testable import TalkText

@MainActor
final class EngineHotKeyServiceFake: GlobalHotKeyService {
    private(set) var uninstallCount = 0

    func install(
        action: @escaping @MainActor @Sendable (RightOptionKeyPhase) -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        .success(())
    }

    func uninstall() {
        uninstallCount += 1
    }
}

@MainActor
final class EngineReadyCueFake: RecordingReadyCuePlaying {
    private let completesImmediately: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var playCount = 0
    private(set) var stopCount = 0

    init(completesImmediately: Bool = true) {
        self.completesImmediately = completesImmediately
    }

    func play() async {
        playCount += 1
        guard !completesImmediately else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func stop() {
        stopCount += 1
        complete()
    }
}

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
    /// Loud by default so tests exercise the transcription path rather than the
    /// silence guard.
    var peakLevel: Float = -12
    var inputDeviceName = "Fake Microphone"
    var preparationResult = true
    var completesPreparationImmediately = true
    var startResult = true
    var completesStartImmediately = true
    var immediateStopOutcome: RecorderStopOutcome? = .finished
    var onStart: (() -> Void)?
    private(set) var maximumDurations: [TimeInterval] = []
    private(set) var preparationCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private var preparationContinuation: CheckedContinuation<Bool, Never>?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var stopContinuation: CheckedContinuation<RecorderStopOutcome, Never>?

    func prepare() async -> Bool {
        preparationCount += 1
        guard !completesPreparationImmediately else {
            return preparationResult
        }
        return await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func completePreparation(with result: Bool? = nil) {
        let result = result ?? preparationResult
        let continuation = preparationContinuation
        preparationContinuation = nil
        continuation?.resume(returning: result)
    }

    func start(maximumDuration: TimeInterval) async -> Bool {
        startCount += 1
        maximumDurations.append(maximumDuration)
        if completesStartImmediately {
            isRecording = startResult
        }
        onStart?()
        guard !completesStartImmediately else {
            return startResult
        }
        return await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func completeStart(with result: Bool? = nil) {
        let result = result ?? startResult
        isRecording = result
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: result)
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
        let preparationContinuation = preparationContinuation
        self.preparationContinuation = nil
        preparationContinuation?.resume(returning: false)
        let startContinuation = startContinuation
        self.startContinuation = nil
        startContinuation?.resume(returning: false)
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

final class EngineSnapshotterFake: ActiveRecordingSnapshotting, @unchecked Sendable {
    private let lock = NSLock()
    var result: Bool
    private var _requests: [(source: URL, destination: URL)] = []

    init(result: Bool = false) {
        self.result = result
    }

    var requests: [(source: URL, destination: URL)] {
        lock.withLock { _requests }
    }

    func createSnapshot(from sourceURL: URL, at destinationURL: URL) async -> Bool {
        lock.withLock {
            _requests.append((sourceURL, destinationURL))
        }
        return result
    }
}

actor EngineGatedSnapshotter: ActiveRecordingSnapshotting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var destination: URL?

    func createSnapshot(from sourceURL: URL, at destinationURL: URL) async -> Bool {
        destination = destinationURL
        await withCheckedContinuation { continuation = $0 }
        // Model an atomic write already in flight when cancellation arrives.
        try? Data("snapshot".utf8).write(to: destinationURL)
        return true
    }

    func complete() {
        continuation?.resume()
        continuation = nil
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

final class EngineSequencedTranscriberFake: WhisperTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [TranscriptionOutcome]
    private var _audioURLs: [URL] = []

    init(outcomes: [TranscriptionOutcome]) {
        self.outcomes = outcomes
    }

    var audioURLs: [URL] {
        lock.withLock { _audioURLs }
    }

    func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        lock.withLock {
            _audioURLs.append(audioURL)
            guard !outcomes.isEmpty else {
                return .noSpeech
            }
            return outcomes.removeFirst()
        }
    }
}

@MainActor
final class EngineDeliveryFake: TextDelivering {
    var capturedTarget: PasteTarget?
    var outcome: DeliveryOutcome?
    var liveUpdateResult = true
    private(set) var captureCount = 0
    private(set) var liveUpdatedTexts: [String] = []
    private(set) var finalizedTexts: [String] = []
    private(set) var liveCancellationCount = 0
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

    func updateLiveTranscript(_ text: String, in target: PasteTarget?) -> Bool {
        liveUpdatedTexts.append(text)
        return liveUpdateResult
    }

    func finalizeLiveTranscript(_ text: String, in target: PasteTarget?) async -> DeliveryOutcome {
        finalizedTexts.append(text)
        return await deliver(text, to: target)
    }

    func cancelLiveTranscript() {
        liveCancellationCount += 1
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
