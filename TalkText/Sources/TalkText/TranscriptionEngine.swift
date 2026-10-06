import AppKit
import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "engine")

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
        let modelRecovery: ModelRecovery?

        init(
            state: State,
            statusText: String,
            modelRecovery: ModelRecovery? = nil
        ) {
            self.state = state
            self.statusText = statusText
            self.modelRecovery = modelRecovery
        }
    }

    struct ModelRecovery: Equatable, Sendable {
        let message: String
        let command: String
        let copyButtonTitle: String

        static let setup = ModelRecovery(
            message: "Parakeet models are unavailable. Run setup from the TalkText checkout, or reinstall the app:",
            command: "./setup.sh",
            copyButtonTitle: "Copy Setup Command"
        )
    }

    @Published private(set) var state: State
    @Published private(set) var statusText: String
    @Published private(set) var modelRecovery: ModelRecovery?

    var isInteractive: Bool {
        state == .idle || state == .failed
    }

    private let permissionProvider: any MicrophonePermissionProviding
    private let recorderFactory: any AudioRecorderCreating
    private let recordingReadyCue: any RecordingReadyCuePlaying
    private let recordingStoppedCue: any RecordingStoppedCuePlaying
    private let recordingFileStore: any RecordingFileStoring
    let dependencyPreflight: any TranscriptionPreflighting
    private let transcriber: any SpeechTranscribing
    private let textDelivery: any TextDelivering
    private let applicationBundleIdentifier: String?
    private let maximumDuration: TimeInterval
    private let livePreviewInterval: TimeInterval
    private let livePreview: LiveTranscriptionPreview

    /// Peak level below which a recording holds no speech. Real speech peaks far
    /// above this even from across a room; digital silence sits at -infinity.
    /// Reject recordings below the input floor before invoking a recognizer.
    static let silenceFloor: Float = -55

    var currentSessionIdentifier: UUID?
    private var currentSessionTarget: PasteTarget?
    private var currentRecordingURL: URL?
    private var currentRecorder: (any AudioRecording)?
    private var activeTask: Task<Void, Never>?
    var dependencyPreparationTask: Task<TalkTextDependencyPreflightResult, Never>?
    private var dependencyPresentationTask: Task<Void, Never>?
    var cachedDependencyPreflight: TalkTextDependencyPreflightResult?

    init(
        permissionProvider: any MicrophonePermissionProviding,
        recorderFactory: any AudioRecorderCreating,
        recordingReadyCue: any RecordingReadyCuePlaying = SystemRecordingReadyCuePlayer(),
        recordingStoppedCue: any RecordingStoppedCuePlaying = SystemRecordingStoppedCuePlayer(),
        recordingFileStore: any RecordingFileStoring,
        recordingSnapshotter: any ActiveRecordingSnapshotting = ActiveWAVRecordingSnapshotter(),
        dependencyPreflight: any TranscriptionPreflighting,
        transcriber: any SpeechTranscribing,
        textDelivery: any TextDelivering,
        applicationBundleIdentifier: String? = AppIdentity.bundleIdentifier,
        maximumDuration: TimeInterval = TranscriptionEngine.maximumRecordingDuration,
        livePreviewInterval: TimeInterval = 0.5,
        performStartupCleanup: Bool = true,
        startupPresentation: Presentation? = nil
    ) {
        self.permissionProvider = permissionProvider
        self.recorderFactory = recorderFactory
        self.recordingReadyCue = recordingReadyCue
        self.recordingStoppedCue = recordingStoppedCue
        self.recordingFileStore = recordingFileStore
        self.dependencyPreflight = dependencyPreflight
        self.transcriber = transcriber
        self.textDelivery = textDelivery
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.maximumDuration = maximumDuration
        self.livePreviewInterval = max(0.1, livePreviewInterval)
        livePreview = LiveTranscriptionPreview(
            recordingFileStore: recordingFileStore,
            recordingSnapshotter: recordingSnapshotter,
            transcriber: transcriber
        )
        state = startupPresentation?.state ?? .idle
        statusText = startupPresentation?.statusText ?? "Hold Right Option to record, double-tap to lock"
        modelRecovery = startupPresentation?.modelRecovery

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

    /// Runs the canonical dependency preflight at launch and caches its typed
    /// result. Recording reuses this task/result; transcription also rechecks
    /// the local asset layout before invoking Parakeet.
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
                statusText: "Loading Parakeet…"
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
                        statusText: "Ready. Hold Right Option to record, double-tap to lock"
                    )
                )
            case let .failure(failure):
                self.transition(to: Self.presentation(for: failure))
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
                statusText: "Operation cancelled. Hold Right Option to try again."
            )
        )
        logger.notice("Engine operation cancelled")
    }

    /// Synchronous lifecycle hook for normal application termination. Pending
    /// native work is cancelled and session audio is removed before returning.
    /// An in-flight Core ML prediction may finish its current call; its result
    /// is discarded by the cancelled task and invalidated session.
    func cleanup() {
        invalidateCurrentSession()
        transcriber.cancelActiveTranscriptions()
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

    func startRecordingFlow() {
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
                statusText: "Loading Parakeet…"
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
                self.finishFailure(Self.presentation(for: failure))
            }
        }
    }

    func cancelPendingRecordingStart() {
        invalidateCurrentSession()
        transition(
            to: Presentation(
                state: .idle,
                statusText: "Ready. Hold Right Option to record, double-tap to lock"
            )
        )
        logger.notice("Recording start cancelled when right Option was released")
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
        recordingStoppedCue.stop()
        transition(to: Presentation(state: .starting, statusText: "Connecting to microphone…"))

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
            activeTask = Task { @MainActor [weak self, recorder] in
                // Capture the cursor before connecting a Bluetooth input or playing the cue.
                if let self {
                    _ = await self.textDelivery.updateLiveTranscript("", in: self.currentSessionTarget)
                }
                guard !Task.isCancelled else { recorder.cancel(); return }
                let prepared = await recorder.prepare()
                guard let self else {
                    recorder.cancel()
                    return
                }
                guard !Task.isCancelled,
                      self.currentSessionIdentifier == sessionIdentifier,
                      self.state == .starting else {
                    recorder.cancel()
                    return
                }
                guard prepared else {
                    self.activeTask = nil
                    self.finishFailure(
                        "The microphone could not become ready. TalkText retried the selected input; check Input and try again."
                    )
                    return
                }

                self.transition(to: Presentation(state: .starting, statusText: "Ready to record…"))
                await self.recordingReadyCue.play()
                guard !Task.isCancelled,
                      self.currentSessionIdentifier == sessionIdentifier,
                      self.state == .starting else {
                    recorder.cancel()
                    return
                }
                self.transition(to: Presentation(state: .starting, statusText: "Starting recording…"))
                let started = await recorder.start(maximumDuration: self.maximumDuration)
                guard !Task.isCancelled,
                      self.currentSessionIdentifier == sessionIdentifier,
                      self.state == .starting else {
                    recorder.cancel()
                    return
                }
                self.activeTask = nil
                guard started, recorder.isRecording else {
                    self.finishFailure(
                        "The microphone recorder could not start because no audio arrived. TalkText retried the selected input; check Input and try again."
                    )
                    return
                }

                self.transition(
                    to: Presentation(
                        state: .recording,
                        statusText: "Recording… Release or tap Right Option to stop"
                    )
                )
                self.livePreview.start(
                    recordingURL: recordingURL,
                    interval: self.livePreviewInterval
                ) { [weak self] text in
                    guard let self,
                          self.currentSessionIdentifier == sessionIdentifier,
                          self.state == .recording,
                          self.currentRecorderHasAudio else {
                        return
                    }
                    _ = await self.textDelivery.updateLiveTranscript(
                        text,
                        in: self.currentSessionTarget
                    )
                }
                logger.notice(
                    "Recording started with verified input; device: \(recorder.inputDeviceName, privacy: .public)"
                )
            }
        } catch AudioRecorderCreationError.noInputDevice {
            currentRecorder = nil
            removeCurrentRecording()
            finishFailure("No microphone is available. Connect one, then pick it under Input in the TalkText menu.")
            logger.error("Audio recorder creation found no input device")
        } catch {
            currentRecorder = nil
            removeCurrentRecording()
            finishFailure("The microphone recorder could not be created. Check the input device and try again.")
            logger.error("Audio recorder creation failed")
        }
    }

    func stopRecordingFlow() {
        guard let sessionIdentifier = currentSessionIdentifier,
              let recorder = currentRecorder else {
            finishFailure("No active recorder was available. Please try again.")
            return
        }

        transition(to: Presentation(state: .stopping, statusText: "Finalizing recording…"))
        _ = livePreview.stop()
        activeTask = Task { @MainActor [weak self, recorder] in
            let outcome = await recorder.stop()
            if let self, self.currentSessionIdentifier == sessionIdentifier, self.state == .stopping {
                self.recordingStoppedCue.play()
            }
            // Preview/final decoders are independent. Cancel drafts immediately
            // and start the final pass without waiting for preview cleanup.
            guard let self,
                  self.currentSessionIdentifier == sessionIdentifier,
                  self.state == .stopping else {
                return
            }
            self.activeTask = nil
            self.currentRecorder = nil

            switch outcome {
            case .finished:
                guard self.confirmCapturedAudio(from: recorder) else {
                    return
                }
                self.beginTranscription(sessionIdentifier: sessionIdentifier)
            case .notRecording, .unsuccessfulCompletion:
                self.finishFailure("Recording ended unexpectedly. Check the input device and try again.")
            case .finalizationTimedOut:
                self.finishFailure("Recording could not be finalized. Check the input device and try again.")
            case .encodeError:
                self.finishFailure("The recording could not be encoded. Check disk space and the input device.")
            case .cancelled:
                self.finishFailure("Recording was cancelled. Hold Right Option to try again.")
            }
        }
    }

    private func handleRecorderEvent(_ event: RecorderEvent, sessionIdentifier: UUID) {
        guard currentSessionIdentifier == sessionIdentifier,
              currentRecorder != nil,
              state == .starting || state == .recording || state == .stopping else {
            return
        }

        switch event {
        case .maximumDurationReached where state == .recording:
            recordingStoppedCue.play()
            guard let recorder = currentRecorder,
                  confirmCapturedAudio(from: recorder) else { return }
            currentRecorder = nil
            transition(
                to: Presentation(
                    state: .stopping,
                    statusText: "Maximum recording length reached. Finalizing…"
                )
            )
            _ = livePreview.stop()
            activeTask = Task { @MainActor [weak self] in
                guard let self,
                      self.currentSessionIdentifier == sessionIdentifier,
                      self.state == .stopping else {
                    return
                }
                self.activeTask = nil
                self.beginTranscription(sessionIdentifier: sessionIdentifier)
            }
        case .interrupted:
            logger.error("Recording was interrupted")
            finishFailure("Recording was interrupted. Check the input device and try again.")
        case .deviceUnavailable:
            logger.error("Recorder reported the input device as unavailable")
            finishFailure("The microphone became unavailable. Reconnect it and try again.")
        case .encodeError:
            logger.error("Recorder reported an encode error")
            finishFailure("The recording could not be encoded. Check disk space and the input device.")
        case .unexpectedCompletion:
            logger.error("Recorder completed unexpectedly")
            finishFailure("Recording ended unexpectedly. Check the input device and try again.")
        default:
            // A stale or duplicate completion cannot advance another transition.
            break
        }
    }

    private var currentRecorderHasAudio: Bool {
        guard let currentRecorder else {
            return false
        }
        return currentRecorder.peakLevel > Self.silenceFloor
    }

    /// A recording that never rose above the silence floor means the wrong input
    /// was open — usually the built-in microphone while the user speaks into an
    /// interface. Say so instead of inserting any invented transcript.
    private func confirmCapturedAudio(from recorder: any AudioRecording) -> Bool {
        let peak = recorder.peakLevel
        logger.notice(
            """
            Recording finished; device: \(recorder.inputDeviceName, privacy: .public); \
            peak: \(peak, privacy: .public) dBFS
            """
        )
        if peak.isFinite, peak > Self.silenceFloor {
            return true
        }

        finishFailure(
            """
            No sound reached TalkText from \(recorder.inputDeviceName). \
            Pick the microphone you speak into under Input in the TalkText menu.
            """
        )
        return false
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
            textDelivery.cancelLiveTranscript()
            finishSessionKeepingPresentation()
            return
        }

        let target = currentSessionTarget
        let deliveryOutcome = await textDelivery.finalizeLiveTranscript(text, in: target)
        guard currentSessionIdentifier == sessionIdentifier else {
            return
        }
        logger.notice("Delivery completed; characters: \(text.count, privacy: .public)")
        transition(to: Self.presentation(for: deliveryOutcome))
        finishSessionKeepingPresentation()
    }

    private func invalidateCurrentSession() {
        recordingReadyCue.stop()
        recordingStoppedCue.stop()
        currentSessionIdentifier = nil
        currentSessionTarget = nil
        livePreview.cleanup()
        textDelivery.cancelLiveTranscript()
        activeTask?.cancel()
        activeTask = nil
        currentRecorder?.cancel()
        currentRecorder = nil
        removeCurrentRecording()
    }

    private func finishFailure(_ message: String) {
        finishFailure(Presentation(state: .failed, statusText: message))
    }

    private func finishFailure(_ presentation: Presentation) {
        recordingReadyCue.stop()
        livePreview.cleanup()
        textDelivery.cancelLiveTranscript()
        activeTask?.cancel()
        activeTask = nil
        currentRecorder?.cancel()
        currentRecorder = nil
        removeCurrentRecording()
        currentSessionIdentifier = nil
        currentSessionTarget = nil
        transition(to: presentation)
    }

    private func finishSessionKeepingPresentation() {
        activeTask = nil
        livePreview.cleanup()
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
        modelRecovery = presentation.modelRecovery
    }
}
