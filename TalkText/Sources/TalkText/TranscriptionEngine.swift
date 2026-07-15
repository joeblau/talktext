import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.joeblau.talktext", category: "engine")

@MainActor
final class TranscriptionEngine: ObservableObject {
    /// Five minutes bounds disk use and prevents an unattended recording from
    /// continuing indefinitely. Reaching the limit finalizes and transcribes the
    /// recording exactly as if the user had stopped it.
    static let maximumRecordingDuration: TimeInterval = 5 * 60

    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case starting
        case recording
        case stopping
        case transcribing
        case delivering
        case failed
    }

    struct Presentation: Equatable, Sendable {
        let state: State
        let statusText: String
    }

    @Published private(set) var state: State
    @Published private(set) var statusText: String

    var isInteractive: Bool {
        state == .idle || state == .failed
    }

    private let permissionProvider: any MicrophonePermissionProviding
    private let recorderFactory: any AudioRecorderCreating
    private let recordingFileStore: any RecordingFileStoring
    private let dependencyPreflight: any WhisperDependencyPreflighting
    private let transcriber: any WhisperTranscribing
    private let textDelivery: any TextDelivering
    private let applicationBundleIdentifier: String?
    private let maximumDuration: TimeInterval

    private var currentSessionIdentifier: UUID?
    private var currentSessionTarget: PasteTarget?
    private var currentRecordingURL: URL?
    private var currentRecorder: (any AudioRecording)?
    private var activeTask: Task<Void, Never>?
    private var dependencyPreparationTask: Task<TalkTextDependencyPreflightResult, Never>?
    private var dependencyPresentationTask: Task<Void, Never>?
    private var cachedDependencyPreflight: TalkTextDependencyPreflightResult?

    convenience init() {
        let recordingFileStore: any RecordingFileStoring
        let startupPresentation: Presentation?
        do {
            recordingFileStore = try TemporaryRecordingFileStore()
            startupPresentation = nil
        } catch {
            recordingFileStore = UnavailableRecordingFileStore()
            startupPresentation = Presentation(
                state: .failed,
                statusText: "Temporary recording storage is unavailable. Restart TalkText."
            )
        }

        let dependencyResolver = TalkTextDependencyResolver()
        self.init(
            permissionProvider: SystemMicrophonePermissionProvider(),
            recorderFactory: SystemAudioRecorderFactory(),
            recordingFileStore: recordingFileStore,
            dependencyPreflight: dependencyResolver,
            transcriber: WhisperTranscriber(dependencyResolver: dependencyResolver),
            textDelivery: TextDeliveryService(),
            applicationBundleIdentifier: Bundle.main.bundleIdentifier,
            startupPresentation: startupPresentation
        )
    }

    init(
        permissionProvider: any MicrophonePermissionProviding,
        recorderFactory: any AudioRecorderCreating,
        recordingFileStore: any RecordingFileStoring,
        dependencyPreflight: any WhisperDependencyPreflighting,
        transcriber: any WhisperTranscribing,
        textDelivery: any TextDelivering,
        applicationBundleIdentifier: String? = "com.joeblau.talktext",
        maximumDuration: TimeInterval = TranscriptionEngine.maximumRecordingDuration,
        performStartupCleanup: Bool = true,
        startupPresentation: Presentation? = nil
    ) {
        self.permissionProvider = permissionProvider
        self.recorderFactory = recorderFactory
        self.recordingFileStore = recordingFileStore
        self.dependencyPreflight = dependencyPreflight
        self.transcriber = transcriber
        self.textDelivery = textDelivery
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.maximumDuration = maximumDuration
        state = startupPresentation?.state ?? .idle
        statusText = startupPresentation?.statusText ?? "Press Ctrl+Space to record"

        if performStartupCleanup {
            do {
                try recordingFileStore.removeStaleOwnedFiles(
                    olderThan: TemporaryRecordingFileStore.staleFileAge
                )
            } catch {
                logTemporaryFileError(operation: "stale cleanup", error: error)
            }
        }
    }

    func toggleRecording() {
        switch state {
        case .idle, .failed:
            startRecordingFlow()
        case .starting where currentSessionIdentifier == nil:
            // A launch-time dependency check is in flight. Preserve the user's
            // intent and await the same cached task instead of dropping input.
            startRecordingFlow()
        case .recording:
            stopRecordingFlow()
        case .requestingPermission, .starting, .stopping, .transcribing, .delivering:
            logger.debug("Ignored recording toggle while engine is busy")
        }
    }

    /// Runs the canonical dependency preflight at launch and caches its typed
    /// result. Recording reuses this task/result and still re-resolves immediately
    /// before invoking Whisper, so removed or replaced files fail closed.
    func prepareDependencies(forceRefresh: Bool = false) {
        guard currentSessionIdentifier == nil else {
            return
        }
        if forceRefresh {
            cachedDependencyPreflight = nil
            dependencyPreparationTask?.cancel()
            dependencyPreparationTask = nil
        }

        transition(
            to: Presentation(
                state: .starting,
                statusText: "Checking Whisper setup…"
            )
        )
        dependencyPresentationTask?.cancel()
        dependencyPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.dependencyPreflightResult()
            guard !Task.isCancelled, self.currentSessionIdentifier == nil else {
                return
            }
            switch result {
            case .ready:
                self.transition(
                    to: Presentation(
                        state: .idle,
                        statusText: "Ready. Press Ctrl+Space to record"
                    )
                )
            case let .failure(failure):
                self.transition(
                    to: Presentation(state: .failed, statusText: failure.userMessage)
                )
            }
        }
    }

    /// Cancels recording/transcription/delivery, removes session audio, and leaves
    /// an explicit error presentation. This is also useful for deterministic
    /// lifecycle tests; application termination should call `cleanup()` instead.
    func cancelCurrentOperation() {
        guard currentSessionIdentifier != nil else {
            return
        }
        invalidateCurrentSession()
        transition(
            to: Presentation(
                state: .failed,
                statusText: "Operation cancelled. Press Ctrl+Space to try again."
            )
        )
        logger.notice("Engine operation cancelled")
    }

    /// Synchronous lifecycle hook for normal application termination. Active
    /// subprocesses are force-killed and confirmed terminated, and audio files
    /// are removed before this method returns.
    func cleanup() {
        invalidateCurrentSession()
        transcriber.terminateActiveTranscriptions()
        dependencyPresentationTask?.cancel()
        dependencyPresentationTask = nil
        dependencyPreparationTask?.cancel()
        dependencyPreparationTask = nil
        do {
            try recordingFileStore.cleanupInstance()
        } catch {
            logTemporaryFileError(operation: "instance cleanup", error: error)
        }
    }

    private func startRecordingFlow() {
        activeTask?.cancel()
        activeTask = nil
        dependencyPresentationTask?.cancel()
        dependencyPresentationTask = nil

        if dependencyPreparationTask == nil {
            // Dependencies can be removed, replaced, or made unreadable after
            // launch. Re-check every recording intent before microphone access.
            cachedDependencyPreflight = nil
        }

        let sessionIdentifier = UUID()
        currentSessionIdentifier = sessionIdentifier
        currentSessionTarget = textDelivery.captureCurrentTarget(
            excludingBundleIdentifier: applicationBundleIdentifier
        )

        transition(
            to: Presentation(
                state: .starting,
                statusText: "Checking Whisper setup…"
            )
        )
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.dependencyPreflightResult()
            guard self.currentSessionIdentifier == sessionIdentifier,
                  self.state == .starting else {
                return
            }
            self.activeTask = nil
            switch result {
            case .ready:
                self.continueRecordingAfterPreflight(sessionIdentifier: sessionIdentifier)
            case let .failure(failure):
                self.finishFailure(failure.userMessage)
            }
        }
    }

    private func continueRecordingAfterPreflight(sessionIdentifier: UUID) {
        guard currentSessionIdentifier == sessionIdentifier else {
            return
        }
        switch permissionProvider.authorizationStatus() {
        case .authorized:
            beginRecording(sessionIdentifier: sessionIdentifier)
        case .notDetermined:
            transition(
                to: Presentation(
                    state: .requestingPermission,
                    statusText: "Waiting for microphone permission…"
                )
            )
            activeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await self.permissionProvider.requestAccess()
                guard self.currentSessionIdentifier == sessionIdentifier,
                      self.state == .requestingPermission else {
                    return
                }
                self.activeTask = nil
                if granted {
                    self.beginRecording(sessionIdentifier: sessionIdentifier)
                } else {
                    self.finishFailure(
                        "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."
                    )
                }
            }
        case .denied:
            finishFailure(
                "Microphone access is denied. Enable it in System Settings > Privacy & Security > Microphone."
            )
        case .restricted:
            finishFailure(
                "Microphone access is restricted on this Mac. Check device or parental-control settings."
            )
        case .unknown:
            finishFailure(
                "Microphone permission could not be determined. Check System Settings and try again."
            )
        }
    }

    private func beginRecording(sessionIdentifier: UUID) {
        guard currentSessionIdentifier == sessionIdentifier else {
            return
        }
        transition(to: Presentation(state: .starting, statusText: "Starting recording…"))

        let recordingURL: URL
        do {
            recordingURL = try recordingFileStore.allocateRecordingURL()
        } catch {
            logTemporaryFileError(operation: "allocation", error: error)
            finishFailure("Couldn’t create a private temporary recording. Check disk space and try again.")
            return
        }
        currentRecordingURL = recordingURL

        do {
            let recorder = try recorderFactory.makeRecorder(at: recordingURL) { [weak self] event in
                self?.handleRecorderEvent(event, sessionIdentifier: sessionIdentifier)
            }
            currentRecorder = recorder
            let started = recorder.start(maximumDuration: maximumDuration)
            guard started, recorder.isRecording else {
                currentRecorder = nil
                if currentSessionIdentifier == sessionIdentifier {
                    finishFailure("The microphone recorder could not start. Check the selected input device.")
                }
                return
            }

            guard currentSessionIdentifier == sessionIdentifier, state == .starting else {
                recorder.cancel()
                return
            }
            transition(
                to: Presentation(
                    state: .recording,
                    statusText: "Recording… Press Ctrl+Space to stop"
                )
            )
            logger.notice("Recording started")
        } catch {
            currentRecorder = nil
            removeCurrentRecording()
            finishFailure("The microphone recorder could not be created. Check the input device and try again.")
            logger.error("Audio recorder creation failed")
        }
    }

    private func stopRecordingFlow() {
        guard let sessionIdentifier = currentSessionIdentifier,
              let recorder = currentRecorder else {
            finishFailure("No active recorder was available. Please try again.")
            return
        }

        transition(to: Presentation(state: .stopping, statusText: "Finalizing recording…"))
        activeTask = Task { @MainActor [weak self, recorder] in
            let outcome = await recorder.stop()
            guard let self,
                  self.currentSessionIdentifier == sessionIdentifier,
                  self.state == .stopping else {
                return
            }
            self.activeTask = nil
            self.currentRecorder = nil

            switch outcome {
            case .finished:
                self.beginTranscription(sessionIdentifier: sessionIdentifier)
            case .notRecording, .unsuccessfulCompletion:
                self.finishFailure("Recording ended unexpectedly. Check the input device and try again.")
            case .finalizationTimedOut:
                self.finishFailure("Recording could not be finalized. Check the input device and try again.")
            case .encodeError:
                self.finishFailure("The recording could not be encoded. Check disk space and the input device.")
            case .cancelled:
                self.finishFailure("Recording was cancelled. Press Ctrl+Space to try again.")
            }
        }
    }

    private func handleRecorderEvent(_ event: RecorderEvent, sessionIdentifier: UUID) {
        guard currentSessionIdentifier == sessionIdentifier else {
            return
        }

        switch event {
        case .maximumDurationReached where state == .recording:
            currentRecorder = nil
            transition(
                to: Presentation(
                    state: .stopping,
                    statusText: "Maximum recording length reached. Finalizing…"
                )
            )
            beginTranscription(sessionIdentifier: sessionIdentifier)
        case .interrupted:
            currentRecorder = nil
            finishFailure("Recording was interrupted. Check the input device and try again.")
        case .deviceUnavailable:
            currentRecorder = nil
            finishFailure("The microphone became unavailable. Reconnect it and try again.")
        case .encodeError:
            currentRecorder = nil
            finishFailure("The recording could not be encoded. Check disk space and the input device.")
        case .unexpectedCompletion:
            currentRecorder = nil
            finishFailure("Recording ended unexpectedly. Check the input device and try again.")
        default:
            // A stale or duplicate completion cannot advance another transition.
            break
        }
    }

    private func beginTranscription(sessionIdentifier: UUID) {
        guard currentSessionIdentifier == sessionIdentifier,
              let recordingURL = currentRecordingURL else {
            return
        }
        transition(to: Presentation(state: .transcribing, statusText: "Transcribing…"))

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.transcriber.transcribe(audioURL: recordingURL)
            guard self.currentSessionIdentifier == sessionIdentifier else {
                return
            }

            self.removeCurrentRecording()
            await self.handleTranscriptionOutcome(
                outcome,
                sessionIdentifier: sessionIdentifier
            )
        }
    }

    private func handleTranscriptionOutcome(
        _ outcome: TranscriptionOutcome,
        sessionIdentifier: UUID
    ) async {
        logTranscriptionOutcome(outcome)
        let outcomePresentation = Self.presentation(for: outcome)
        transition(to: outcomePresentation)

        guard case let .success(text) = outcome else {
            finishSessionKeepingPresentation()
            return
        }

        let target = currentSessionTarget
        let deliveryOutcome = await textDelivery.deliver(text, to: target)
        guard currentSessionIdentifier == sessionIdentifier else {
            return
        }
        logger.notice("Delivery completed; characters: \(text.count, privacy: .public)")
        transition(to: Self.presentation(for: deliveryOutcome))
        finishSessionKeepingPresentation()
    }

    private func invalidateCurrentSession() {
        currentSessionIdentifier = nil
        currentSessionTarget = nil
        activeTask?.cancel()
        activeTask = nil
        currentRecorder?.cancel()
        currentRecorder = nil
        removeCurrentRecording()
    }

    private func finishFailure(_ message: String) {
        activeTask?.cancel()
        activeTask = nil
        currentRecorder?.cancel()
        currentRecorder = nil
        removeCurrentRecording()
        currentSessionIdentifier = nil
        currentSessionTarget = nil
        transition(to: Presentation(state: .failed, statusText: message))
    }

    private func finishSessionKeepingPresentation() {
        activeTask = nil
        currentRecorder = nil
        currentRecordingURL = nil
        currentSessionIdentifier = nil
        currentSessionTarget = nil
    }

    private func removeCurrentRecording() {
        guard let recordingURL = currentRecordingURL else {
            return
        }
        currentRecordingURL = nil
        do {
            try recordingFileStore.removeRecording(at: recordingURL)
        } catch {
            logTemporaryFileError(operation: "session cleanup", error: error)
        }
    }

    private func transition(to presentation: Presentation) {
        state = presentation.state
        statusText = presentation.statusText
    }

    private func logTemporaryFileError(operation: StaticString, error: any Error) {
        let errorType = String(describing: type(of: error))
        logger.error(
            "Temporary recording \(operation, privacy: .public) failed; error type: \(errorType, privacy: .public)"
        )
    }

    private func logTranscriptionOutcome(_ outcome: TranscriptionOutcome) {
        switch outcome {
        case let .success(text):
            logger.notice("Transcription succeeded; characters: \(text.count, privacy: .public)")
        case .noSpeech:
            logger.notice("Transcription succeeded with no speech")
        case let .missingDependency(dependency):
            logger.error(
                "Transcription dependency missing; kind: \(String(describing: dependency), privacy: .public)"
            )
        case let .invalidAudio(reason):
            logger.error(
                "Transcription rejected invalid audio; reason: \(String(describing: reason), privacy: .public)"
            )
        case let .launchFailed(diagnostic):
            logger.error(
                "Transcription process launch failed; domain: \(diagnostic.launchErrorDomain ?? "unknown", privacy: .private), code: \(diagnostic.launchErrorCode ?? -1, privacy: .public)"
            )
        case let .processFailed(diagnostic):
            logProcessDiagnostic("failed", diagnostic: diagnostic)
        case let .timedOut(diagnostic):
            logProcessDiagnostic("timed out", diagnostic: diagnostic)
        case let .cancelled(diagnostic):
            logProcessDiagnostic("cancelled", diagnostic: diagnostic)
        }
    }

    private func logProcessDiagnostic(_ outcome: StaticString, diagnostic: ProcessDiagnostic) {
        logger.error(
            "Transcription process \(outcome, privacy: .public); reason: \(String(describing: diagnostic.terminationReason), privacy: .public), status: \(diagnostic.terminationStatus ?? -1, privacy: .public), stdout bytes: \(diagnostic.standardOutput.count, privacy: .public), stderr bytes: \(diagnostic.standardError.count, privacy: .public)"
        )
    }

    private func dependencyPreflightResult() async -> TalkTextDependencyPreflightResult {
        if let cachedDependencyPreflight {
            return cachedDependencyPreflight
        }
        if let dependencyPreparationTask {
            return await dependencyPreparationTask.value
        }

        let preflight = dependencyPreflight
        let task = Task {
            await preflight.preflightDependencies()
        }
        dependencyPreparationTask = task
        let result = await task.value
        dependencyPreparationTask = nil
        cachedDependencyPreflight = result
        logDependencyPreflight(result)
        return result
    }

    private func logDependencyPreflight(_ result: TalkTextDependencyPreflightResult) {
        switch result {
        case let .ready(preflight):
            logger.notice(
                "Dependency preflight ready; \(preflight.diagnosticSummary, privacy: .public); binary: \(preflight.backend.executable.url.path, privacy: .private(mask: .hash)); model: \(preflight.model.url.path, privacy: .private(mask: .hash))"
            )
        case let .failure(failure):
            logger.error(
                "Dependency preflight failed; category: \(Self.preflightFailureCategory(failure), privacy: .public)"
            )
        }
    }
}

@MainActor
private final class UnavailableRecordingFileStore: RecordingFileStoring {
    func allocateRecordingURL() throws -> URL {
        throw RecordingFileStoreError.unableToAllocateRecording
    }

    func removeRecording(at url: URL) throws {}
    func removeStaleOwnedFiles(olderThan age: TimeInterval) throws {}
    func cleanupInstance() throws {}
}
