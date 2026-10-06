@preconcurrency import AVFoundation
import AppKit
import Foundation
import os

private let recorderLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "recorder")

/// Opens only the selected input, with bounded Bluetooth settling and recovery.
/// CoreAudio setup and teardown run on MicrophoneInput, keeping key-up responsive.
@MainActor
final class SystemAudioRecorder: NSObject, AudioRecording {
    private static let startupAttemptCount = 3
    private static let readinessTimeout: Duration = .seconds(3)
    private static let pollInterval: Duration = .milliseconds(20)

    private let inputResolver: any AudioInputResolving
    private let sink: CapturedAudioSink
    private let input: any MicrophoneInputDriving
    private let eventHandler: @MainActor (RecorderEvent) -> Void
    private var activeDevice: AudioInputDevice?
    private var prepared = false
    private var running = false
    private var starting = false
    private var cancelled = false
    private var maximumDurationTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var completionTask: Task<RecorderStopOutcome, Never>?
    private var sleepObserver: NSObjectProtocol?

    var isRecording: Bool { running }
    var peakLevel: Float { sink.peakLevel }
    var inputDeviceName: String { activeDevice?.name ?? "Microphone" }

    init(
        url: URL,
        inputResolver: any AudioInputResolving,
        input: any MicrophoneInputDriving = MicrophoneInput(),
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws {
        self.inputResolver = inputResolver
        self.input = input
        self.eventHandler = eventHandler
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        sink = CapturedAudioSink(file: file)
        super.init()
        sink.errorHandler = { [weak self] diagnostic in
            Task { @MainActor [weak self] in self?.handleWriteFailure(diagnostic) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopAutomatically(event: .interrupted) }
        }
    }

    deinit {
        maximumDurationTask?.cancel()
        healthTask?.cancel()
        input.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    func prepare() async -> Bool {
        guard !prepared, !running, !starting, !cancelled else { return false }
        starting = true
        defer { starting = false }
        prepared = await openInputWithRetries()
        return prepared
    }

    func start(maximumDuration: TimeInterval) async -> Bool {
        guard prepared, !running, !starting, !cancelled else { return false }
        starting = true
        defer { starting = false }
        // One verified WAV write proves both the post-cue input and resampler
        // are ready. A separate pre-write wait added an unnecessary buffer delay.
        let baseline = sink.writtenBufferCount
        guard sink.beginCapturing() else { return false }
        var ready = await waitForInput(after: baseline, written: true)
        if !ready, !cancelled, !Task.isCancelled, sink.pendingErrorDiagnostic == nil {
            ready = await openInputWithRetries()
            if ready { ready = await waitForInput(after: baseline, written: true) }
        }
        prepared = false
        guard ready, !cancelled, !Task.isCancelled else {
            await input.close()
            return false
        }
        running = true
        maximumDurationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.1, maximumDuration))) } catch { return }
            self?.stopAutomatically(event: .maximumDurationReached)
        }
        monitorInputHealth()
        return true
    }

    func stop() async -> RecorderStopOutcome {
        // Key-up can coincide with the time limit or a device-loss stop. Share
        // finalization instead of reporting a spurious "not recording" error.
        if let completionTask { return await completionTask.value }
        guard running else { return .notRecording }
        running = false
        cancelTimers()
        let completion = Task { @MainActor [self] in await finalizeCapture() }
        completionTask = completion
        return await completion.value
    }

    private func finalizeCapture() async -> RecorderStopOutcome {
        // Stops callbacks and drains the audio writer before finalizing the file.
        await input.close()
        guard !cancelled else { return .cancelled }
        let closed = sink.close()
        if let diagnostic = sink.pendingErrorDiagnostic {
            return .encodeError(diagnostic)
        }
        return closed ? .finished : .unsuccessfulCompletion
    }

    func cancel() {
        cancelled = true
        prepared = false
        running = false
        cancelTimers()
        completionTask?.cancel()
        completionTask = nil
        input.cancel()
        _ = sink.close()
    }

    private func cancelTimers() {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        healthTask?.cancel()
        healthTask = nil
    }

    private func handleWriteFailure(_ diagnostic: RecorderErrorDiagnostic) {
        guard running else { return }
        running = false
        cancelTimers()
        input.cancel()
        _ = sink.close()
        eventHandler(.encodeError(diagnostic))
    }

    private func openInputWithRetries() async -> Bool {
        for attempt in 1...Self.startupAttemptCount {
            guard !cancelled, !Task.isCancelled else { return false }
            if let device = inputResolver.resolveInputDevice() {
                activeDevice = device
                let baseline = sink.receivedBufferCount
                do {
                    try await input.open(deviceID: device.deviceID, sink: sink)
                    if await waitForInput(after: baseline, written: false) {
                        recorderLogger.notice("Audio input ready; device: \(device.name, privacy: .public); attempt: \(attempt, privacy: .public)")
                        return true
                    }
                } catch {
                    let diagnostic = error as NSError
                    recorderLogger
                        .error(
                            "Audio input start failed; attempt: \(attempt, privacy: .public); domain: \(diagnostic.domain, privacy: .public); code: \(diagnostic.code, privacy: .public)"
                        )
                }
            }
            await input.close()
            guard attempt < Self.startupAttemptCount, !cancelled, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(100 * attempt)) } catch { return false }
        }
        return false
    }

    private func waitForInput(after baseline: UInt64, written: Bool) async -> Bool {
        await AudioInputReadiness.wait(
            after: baseline, generation: 0, requiredBuffers: written ? 1 : 2,
            timeout: Self.readinessTimeout, pollInterval: Self.pollInterval,
            sample: {
                .init(generation: 0, bufferCount: written ? self.sink.writtenBufferCount : self.sink.receivedBufferCount,
                      isRunning: self.input.health.isRunning,
                      hasError: self.cancelled || self.sink.pendingErrorDiagnostic != nil)
            },
            restart: {
                guard !self.cancelled, !Task.isCancelled, let device = self.inputResolver.resolveInputDevice() else { return false }
                self.activeDevice = device
                do {
                    try await self.input.open(deviceID: device.deviceID, sink: self.sink)
                    return true
                } catch { return false }
            }
        )
    }

    /// Detect a stalled capture even without a configuration notification. Silent
    /// samples still count as a healthy route; speech detection uses the peak level.
    private func monitorInputHealth() {
        healthTask = Task { @MainActor [weak self] in
            var previousCount: UInt64 = 0
            var stalledChecks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.running, !self.cancelled else { return }
                let count = self.sink.writtenBufferCount
                stalledChecks = count == previousCount ? stalledChecks + 1 : 0
                previousCount = count
                let selected = self.inputResolver.resolveInputDevice()
                let routeChanged = selected?.deviceID != self.activeDevice?.deviceID
                guard routeChanged || !self.input.health.isRunning || stalledChecks >= 3 else { continue }
                recorderLogger.notice("Recovering a stalled or changed microphone input")
                guard await self.openInputWithRetries() else {
                    guard !Task.isCancelled, self.running, !self.cancelled else { return }
                    self.stopAutomatically(event: .deviceUnavailable)
                    return
                }
                stalledChecks = 0
                previousCount = self.sink.writtenBufferCount
            }
        }
    }

    private func stopAutomatically(event: RecorderEvent) {
        guard running else { return }
        running = false
        cancelTimers()
        let completion = Task { @MainActor [self] in await finalizeCapture() }
        completionTask = completion
        Task { @MainActor [weak self] in
            let outcome = await completion.value
            guard let self, !self.cancelled else { return }
            switch outcome {
            case .finished: self.eventHandler(event)
            case let .encodeError(diagnostic): self.eventHandler(.encodeError(diagnostic))
            default: self.eventHandler(.unexpectedCompletion)
            }
        }
    }
}
