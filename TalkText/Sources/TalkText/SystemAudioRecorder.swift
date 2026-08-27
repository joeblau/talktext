@preconcurrency import AVFoundation
import AppKit
import Foundation
import os

private let recorderLogger = Logger(
    subsystem: AppIdentity.bundleIdentifier,
    category: "recorder"
)
/// Records from one explicitly chosen input device.
///
/// `AVAudioRecorder` always follows the system default input, which silently
/// records the wrong microphone whenever a Mac has an audio interface and the
/// user speaks into it. An `AVAudioEngine` input node can be bound to a specific
/// `AudioDeviceID`, so TalkText drives the AUHAL directly, downmixes channel one
/// to mono, resamples to the 16 kHz Whisper expects, and appends to the same
/// growing WAV file the live preview snapshots.
@MainActor
final class SystemAudioRecorder: NSObject, AudioRecording {
    private enum AutomaticStopReason {
        case maximumDuration
        case interruption
        case deviceUnavailable
    }

    /// AirPods and other Bluetooth inputs can take several seconds to switch
    /// from playback to their duplex profile. Each attempt gets enough time to
    /// settle, but the total remains bounded.
    private static let startupAttemptCount = 3
    private static let startupReadinessTimeout: Duration = .seconds(3)
    private static let postCueReadinessTimeout: Duration = .seconds(1.5)
    private static let startupPollInterval: Duration = .milliseconds(50)
    private static let requiredReadyBuffers: UInt64 = 2

    private let inputResolver: any AudioInputResolving
    private let sink: CapturedAudioSink
    private let eventHandler: @MainActor (RecorderEvent) -> Void
    private var engine: AVAudioEngine?
    private var engineHasTap = false
    private var activeEngineIdentifier: UUID?
    private var configurationObserver: NSObjectProtocol?
    private var configurationGeneration: UInt64 = 0
    private var activeDevice: AudioInputDevice?
    private var lastInputDeviceName = "Microphone"
    private var prepared = false
    private var running = false
    private var starting = false
    private var recovering = false
    private var cancelled = false
    private var maximumDurationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []

    var isRecording: Bool {
        running
    }

    var peakLevel: Float {
        sink.peakLevel
    }

    var inputDeviceName: String {
        activeDevice?.name ?? lastInputDeviceName
    }

    init(
        url: URL,
        inputResolver: any AudioInputResolving,
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws {
        self.inputResolver = inputResolver
        self.eventHandler = eventHandler

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        sink = CapturedAudioSink(file: file)
        super.init()

        sink.errorHandler = { [weak self] diagnostic in
            Task { @MainActor [weak self] in
                self?.handleWriteFailure(diagnostic)
            }
        }
        installInterruptionObservers()
    }

    deinit {
        maximumDurationTask?.cancel()
        recoveryTask?.cancel()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func prepare() async -> Bool {
        guard !prepared, !running, !starting, !recovering else {
            return false
        }
        cancelled = false
        starting = true
        defer { starting = false }

        guard await openInputWithRetries() else {
            teardownCurrentEngine()
            return false
        }
        guard !cancelled, !Task.isCancelled else {
            teardownCurrentEngine()
            return false
        }
        prepared = true
        return true
    }

    func start(maximumDuration: TimeInterval) async -> Bool {
        guard prepared, !running, !starting, !recovering else {
            return false
        }
        starting = true
        defer { starting = false }

        // The ready cue runs while the warmed-up tap discards audio. Confirm a
        // fresh buffer afterwards because output playback can itself provoke a
        // Bluetooth configuration notification.
        let postCueBaseline = sink.receivedBufferCount
        let postCueGeneration = configurationGeneration
        var inputReady = await waitForReadyInput(
            after: postCueBaseline,
            configurationGeneration: postCueGeneration,
            requiredBuffers: 1,
            timeout: Self.postCueReadinessTimeout
        )
        if !inputReady {
            recorderLogger.notice("Input route changed during the ready cue; rebuilding it")
            inputReady = await openInputWithRetries()
        }
        guard inputReady, !cancelled, !Task.isCancelled else {
            prepared = false
            teardownCurrentEngine()
            return false
        }

        let writeBaseline = sink.writtenBufferCount
        guard sink.beginCapturing() else {
            prepared = false
            teardownCurrentEngine()
            return false
        }
        var wroteAudio = await waitForWrittenInput(after: writeBaseline)
        if !wroteAudio, sink.pendingErrorDiagnostic == nil {
            recorderLogger.notice("Input stopped before the first WAV write; rebuilding it")
            if await openInputWithRetries() {
                wroteAudio = await waitForWrittenInput(after: writeBaseline)
            }
        }
        guard wroteAudio, !cancelled, !Task.isCancelled else {
            prepared = false
            teardownCurrentEngine()
            return false
        }

        prepared = false
        running = true
        scheduleMaximumDuration(maximumDuration)
        return true
    }

    func stop() async -> RecorderStopOutcome {
        guard running else {
            return .notRecording
        }

        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        running = false
        teardownCurrentEngine()
        if let diagnostic = sink.pendingErrorDiagnostic {
            _ = sink.close()
            return .encodeError(diagnostic)
        }
        return sink.close() ? .finished : .unsuccessfulCompletion
    }

    func cancel() {
        cancelled = true
        prepared = false
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        running = false
        teardownCurrentEngine()
        _ = sink.close()
    }

    private func handleWriteFailure(_ diagnostic: RecorderErrorDiagnostic) {
        guard running else {
            return
        }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        running = false
        teardownCurrentEngine()
        _ = sink.close()
        eventHandler(.encodeError(diagnostic))
    }

    private func scheduleMaximumDuration(_ maximumDuration: TimeInterval) {
        let duration = max(0.1, maximumDuration)
        maximumDurationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            self?.stopAutomatically(for: .maximumDuration)
        }
    }

    /// Opens a brand-new graph for every attempt. CoreAudio device IDs are
    /// ephemeral during route churn, so the stable preference is resolved back
    /// to a current ID immediately before each bind.
    private func openInputWithRetries() async -> Bool {
        for attempt in 1 ... Self.startupAttemptCount {
            guard !cancelled, !Task.isCancelled else {
                return false
            }

            teardownCurrentEngine()
            guard let device = inputResolver.resolveInputDevice() else {
                recorderLogger.error(
                    "No input device while opening recorder; attempt: \(attempt, privacy: .public)"
                )
                if await waitBeforeRetry(after: attempt) {
                    continue
                }
                return false
            }

            activeDevice = device
            lastInputDeviceName = device.name
            let baselineBufferCount = sink.receivedBufferCount
            do {
                try configureAndStartFreshEngine(for: device)
            } catch {
                let nsError = error as NSError
                recorderLogger.error(
                    "Audio input start failed; device: \(device.name, privacy: .public); attempt: \(attempt, privacy: .public); domain: \(nsError.domain, privacy: .public); code: \(nsError.code, privacy: .public)"
                )
                if await waitBeforeRetry(after: attempt) {
                    continue
                }
                return false
            }

            let generationAtStart = configurationGeneration
            if await waitForReadyInput(
                after: baselineBufferCount,
                configurationGeneration: generationAtStart,
                requiredBuffers: Self.requiredReadyBuffers,
                timeout: Self.startupReadinessTimeout
            ) {
                recorderLogger.notice(
                    "Audio input ready; device: \(device.name, privacy: .public); attempt: \(attempt, privacy: .public)"
                )
                return true
            }

            recorderLogger.error(
                "Audio input produced no stable buffers; device: \(device.name, privacy: .public); attempt: \(attempt, privacy: .public)"
            )
            if await !waitBeforeRetry(after: attempt) {
                return false
            }
        }
        return false
    }

    private func configureAndStartFreshEngine(for device: AudioInputDevice) throws {
        let freshEngine = AVAudioEngine()
        let identifier = UUID()
        engine = freshEngine
        activeEngineIdentifier = identifier
        engineHasTap = false

        try freshEngine.inputNode.auAudioUnit.setDeviceID(device.deviceID)
        let hardwareFormat = freshEngine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioRecorderCreationError.inputDeviceUnusable
        }

        let sink = sink
        // A nil format means "whatever this node produces", which survives
        // sample-rate and channel-layout changes better than a captured format.
        freshEngine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { buffer, _ in
            sink.append(buffer)
        }
        engineHasTap = true
        installConfigurationObserver(for: freshEngine, identifier: identifier)
        freshEngine.prepare()
        try freshEngine.start()
    }

    private func waitForReadyInput(
        after baselineBufferCount: UInt64,
        configurationGeneration expectedGeneration: UInt64,
        requiredBuffers: UInt64,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !cancelled, !Task.isCancelled,
                  configurationGeneration == expectedGeneration,
                  let engine, engine.isRunning,
                  sink.pendingErrorDiagnostic == nil else {
                return false
            }
            if sink.receivedBufferCount >= baselineBufferCount + requiredBuffers {
                return true
            }
            do {
                try await Task.sleep(for: Self.startupPollInterval)
            } catch {
                return false
            }
        }
        return false
    }

    private func waitForWrittenInput(after baselineBufferCount: UInt64) async -> Bool {
        let generation = configurationGeneration
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.postCueReadinessTimeout)
        while clock.now < deadline {
            guard !cancelled, !Task.isCancelled,
                  configurationGeneration == generation,
                  let engine, engine.isRunning,
                  sink.pendingErrorDiagnostic == nil else {
                return false
            }
            if sink.writtenBufferCount > baselineBufferCount {
                return true
            }
            do {
                try await Task.sleep(for: Self.startupPollInterval)
            } catch {
                return false
            }
        }
        return false
    }

    /// Returns true when another attempt remains and the wait was not cancelled.
    private func waitBeforeRetry(after attempt: Int) async -> Bool {
        guard attempt < Self.startupAttemptCount,
              !cancelled,
              !Task.isCancelled else {
            return false
        }
        teardownCurrentEngine()
        let backoff = Duration.milliseconds(150 * attempt)
        do {
            try await Task.sleep(for: backoff)
            return !cancelled && !Task.isCancelled
        } catch {
            return false
        }
    }

    private func installConfigurationObserver(
        for engine: AVAudioEngine,
        identifier: UUID
    ) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange(for: identifier)
            }
        }
    }

    private func teardownCurrentEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        activeEngineIdentifier = nil
        guard let engine else {
            engineHasTap = false
            return
        }
        if engineHasTap {
            engine.inputNode.removeTap(onBus: 0)
            engineHasTap = false
        }
        engine.stop()
        engine.reset()
        self.engine = nil
    }

    private func installInterruptionObservers() {
        let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopAutomatically(for: .interruption)
            }
        }
        notificationObservers.append(sleepObserver)

        let deviceObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handlePossibleDeviceChange()
            }
        }
        notificationObservers.append(deviceObserver)
    }

    /// Route churn can stop and uninitialize the graph. During startup the new
    /// generation invalidates readiness; during recording it schedules a health
    /// check and a fresh-device rebuild if buffers do not continue.
    private func handleConfigurationChange(for engineIdentifier: UUID) {
        guard activeEngineIdentifier == engineIdentifier else {
            return
        }
        configurationGeneration &+= 1
        guard running, !starting, !recovering else {
            return
        }
        scheduleRouteRecovery()
    }

    private func handlePossibleDeviceChange() {
        configurationGeneration &+= 1
        guard running, !starting, !recovering else {
            return
        }
        scheduleRouteRecovery()
    }

    /// A route notification can be followed by a brief period in which the old
    /// graph keeps rendering. Give it one buffer interval before rebuilding;
    /// this avoids interrupting benign notifications while still recovering a
    /// stopped or silent engine automatically.
    private func scheduleRouteRecovery() {
        guard recoveryTask == nil else {
            return
        }
        let bufferCountAtNotification = sink.writtenBufferCount
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self, self.running, !self.cancelled else {
                return
            }
            if let engine = self.engine,
               engine.isRunning,
               self.sink.writtenBufferCount > bufferCountAtNotification {
                self.recoveryTask = nil
                recorderLogger.debug("Audio input remained healthy after a configuration change")
                return
            }

            self.recovering = true
            let recovered = await self.openInputWithRetries()
            self.recovering = false
            self.recoveryTask = nil
            guard self.running, !self.cancelled else {
                return
            }
            if recovered {
                recorderLogger.notice(
                    "Recovered recording after an audio route change; device: \(self.inputDeviceName, privacy: .public)"
                )
                return
            }

            self.running = false
            self.teardownCurrentEngine()
            _ = self.sink.close()
            recorderLogger.error("Could not recover recording after an audio route change")
            self.eventHandler(.deviceUnavailable)
        }
    }

    private func stopAutomatically(for reason: AutomaticStopReason) {
        guard running else {
            return
        }
        recorderLogger.notice(
            "Recording stopped automatically; device: \(self.inputDeviceName, privacy: .public)"
        )
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        running = false
        teardownCurrentEngine()
        let closed = sink.close()

        switch reason {
        case .maximumDuration where closed:
            eventHandler(.maximumDurationReached)
        case .maximumDuration:
            eventHandler(.unexpectedCompletion)
        case .interruption:
            eventHandler(.interrupted)
        case .deviceUnavailable:
            eventHandler(.deviceUnavailable)
        }
    }
}
