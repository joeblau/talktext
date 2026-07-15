@preconcurrency import AVFoundation
import AppKit
import Foundation
import os

private let recordingFileStoreLog = OSLog(
    subsystem: "com.joeblau.talktext",
    category: "recording-file-store"
)

enum MicrophoneAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unknown
}

@MainActor
protocol MicrophonePermissionProviding: AnyObject {
    func authorizationStatus() -> MicrophoneAuthorization
    func requestAccess() async -> Bool
}

@MainActor
final class SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    func authorizationStatus() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

struct RecorderErrorDiagnostic: Equatable, Sendable {
    let domain: String
    let code: Int
}

enum RecorderEvent: Equatable, Sendable {
    case maximumDurationReached
    case interrupted
    case deviceUnavailable
    case encodeError(RecorderErrorDiagnostic)
    case unexpectedCompletion
}

enum RecorderStopOutcome: Equatable, Sendable {
    case finished
    case notRecording
    case encodeError(RecorderErrorDiagnostic)
    case unsuccessfulCompletion
    case finalizationTimedOut
    case cancelled
}

@MainActor
protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    func start(maximumDuration: TimeInterval) -> Bool
    func stop() async -> RecorderStopOutcome
    func cancel()
}

@MainActor
protocol AudioRecorderCreating: AnyObject {
    func makeRecorder(
        at url: URL,
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws -> any AudioRecording
}

@MainActor
final class SystemAudioRecorderFactory: AudioRecorderCreating {
    func makeRecorder(
        at url: URL,
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws -> any AudioRecording {
        try SystemAudioRecorder(url: url, eventHandler: eventHandler)
    }
}

/// AVAudioRecorder adapter that turns delegate callbacks and system interruptions
/// into explicit events. TalkText limits a recording to five minutes by default;
/// the engine supplies that documented limit to `start(maximumDuration:)`.
@MainActor
private final class SystemAudioRecorder: NSObject, AudioRecording, AVAudioRecorderDelegate, @unchecked Sendable {
    private enum AutomaticStopReason {
        case maximumDuration
        case interruption
        case deviceUnavailable
    }

    private let recorder: AVAudioRecorder
    private let eventHandler: @MainActor (RecorderEvent) -> Void
    private var maximumDurationTask: Task<Void, Never>?
    private var stopContinuation: CheckedContinuation<RecorderStopOutcome, Never>?
    private var automaticStopReason: AutomaticStopReason?
    private var notificationObservers: [NSObjectProtocol] = []

    var isRecording: Bool {
        recorder.isRecording
    }

    init(
        url: URL,
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        self.eventHandler = eventHandler
        super.init()
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        installInterruptionObservers()
    }

    deinit {
        maximumDurationTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start(maximumDuration: TimeInterval) -> Bool {
        guard !recorder.isRecording, stopContinuation == nil else {
            return false
        }

        automaticStopReason = nil
        let started = recorder.record()
        guard started else {
            return false
        }

        let duration = max(0.1, maximumDuration)
        maximumDurationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }

            guard let self, self.recorder.isRecording else {
                return
            }
            self.automaticStopReason = .maximumDuration
            self.recorder.stop()
        }
        return true
    }

    func stop() async -> RecorderStopOutcome {
        guard recorder.isRecording else {
            return .notRecording
        }

        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        automaticStopReason = nil

        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
            recorder.stop()

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.stopContinuation != nil else {
                    return
                }
                self.completeRequestedStop(with: .finalizationTimedOut)
            }
        }
    }

    func cancel() {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        automaticStopReason = nil
        if recorder.isRecording {
            recorder.stop()
        }
        completeRequestedStop(with: .cancelled)
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.handleFinishedRecording(successfully: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: (any Error)?
    ) {
        let nsError = error as NSError?
        let diagnostic = RecorderErrorDiagnostic(
            domain: nsError?.domain ?? "AVAudioRecorder",
            code: nsError?.code ?? -1
        )
        Task { @MainActor [weak self] in
            self?.handleEncodeError(diagnostic)
        }
    }

    private func handleFinishedRecording(successfully: Bool) {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil

        if stopContinuation != nil {
            completeRequestedStop(with: successfully ? .finished : .unsuccessfulCompletion)
            return
        }

        let reason = automaticStopReason
        automaticStopReason = nil
        switch reason {
        case .maximumDuration where successfully:
            eventHandler(.maximumDurationReached)
        case .interruption:
            eventHandler(.interrupted)
        case .deviceUnavailable:
            eventHandler(.deviceUnavailable)
        default:
            eventHandler(.unexpectedCompletion)
        }
    }

    private func handleEncodeError(_ diagnostic: RecorderErrorDiagnostic) {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        automaticStopReason = nil
        if stopContinuation != nil {
            completeRequestedStop(with: .encodeError(diagnostic))
        } else {
            eventHandler(.encodeError(diagnostic))
        }
    }

    private func completeRequestedStop(with outcome: RecorderStopOutcome) {
        guard let continuation = stopContinuation else {
            return
        }
        stopContinuation = nil
        continuation.resume(returning: outcome)
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
                self?.stopAutomatically(for: .deviceUnavailable)
            }
        }
        notificationObservers.append(deviceObserver)
    }

    private func stopAutomatically(for reason: AutomaticStopReason) {
        guard recorder.isRecording, stopContinuation == nil else {
            return
        }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        automaticStopReason = reason
        recorder.stop()
    }
}

enum RecordingFileStoreError: Error, Equatable, Sendable {
    case unableToCreateDirectory
    case unableToAllocateRecording
    case cleanupFailed
    case outOfScopeURL
}

@MainActor
protocol RecordingFileStoring: AnyObject {
    func allocateRecordingURL() throws -> URL
    func removeRecording(at url: URL) throws
    func removeStaleOwnedFiles(olderThan age: TimeInterval) throws
    func cleanupInstance() throws
}

@MainActor
final class TemporaryRecordingFileStore: RecordingFileStoring {
    static let staleFileAge: TimeInterval = 24 * 60 * 60

    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let instanceDirectoryURL: URL
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        instanceIdentifier: UUID = UUID(),
        now: @escaping () -> Date = Date.init
    ) throws {
        self.fileManager = fileManager
        self.now = now
        baseDirectoryURL = (temporaryDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("TalkText", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        instanceDirectoryURL = baseDirectoryURL
            .appendingPathComponent("instance-\(instanceIdentifier.uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: instanceDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecordingFileStoreError.unableToCreateDirectory
        }
    }

    func allocateRecordingURL() throws -> URL {
        if !fileManager.fileExists(atPath: instanceDirectoryURL.path) {
            do {
                try fileManager.createDirectory(
                    at: instanceDirectoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw RecordingFileStoreError.unableToAllocateRecording
            }
        }

        return instanceDirectoryURL
            .appendingPathComponent("recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    func removeRecording(at url: URL) throws {
        guard ownsRecordingURL(url) else {
            throw RecordingFileStoreError.outOfScopeURL
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw RecordingFileStoreError.cleanupFailed
        }
    }

    func removeStaleOwnedFiles(olderThan age: TimeInterval = staleFileAge) throws {
        guard fileManager.fileExists(atPath: baseDirectoryURL.path) else {
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: baseDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RecordingFileStoreError.cleanupFailed
        }

        let cutoff = now().addingTimeInterval(-max(0, age))
        var metadataLookupFailed = false
        for url in contents where url.lastPathComponent.hasPrefix("instance-") {
            guard url.standardizedFileURL != instanceDirectoryURL.standardizedFileURL else {
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey]
                )
            } catch {
                let errorType = String(describing: type(of: error))
                os_log(
                    "Stale recording metadata lookup failed; error type: %{public}@",
                    log: recordingFileStoreLog,
                    type: .error,
                    errorType
                )
                metadataLookupFailed = true
                continue
            }
            guard values.isDirectory == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < cutoff else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw RecordingFileStoreError.cleanupFailed
            }
        }
        if metadataLookupFailed {
            throw RecordingFileStoreError.cleanupFailed
        }
    }

    func cleanupInstance() throws {
        guard fileManager.fileExists(atPath: instanceDirectoryURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: instanceDirectoryURL)
        } catch {
            throw RecordingFileStoreError.cleanupFailed
        }
    }

    private func ownsRecordingURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "wav"
            && url.deletingLastPathComponent().standardizedFileURL == instanceDirectoryURL.standardizedFileURL
            && url.lastPathComponent.hasPrefix("recording-")
    }
}

enum AudioValidationFailure: Equatable, Sendable {
    case missing
    case empty
    case unreadableFormat
    case tooShort(duration: TimeInterval)
    case tooLong(duration: TimeInterval)
}

enum AudioValidationResult: Equatable, Sendable {
    case valid(duration: TimeInterval)
    case invalid(AudioValidationFailure)
}

protocol AudioValidating: Sendable {
    func validateAudio(at url: URL) -> AudioValidationResult
}

struct RecordedAudioValidator: AudioValidating, @unchecked Sendable {
    let minimumUsefulDuration: TimeInterval
    let maximumUsefulDuration: TimeInterval
    private let fileManager: FileManager

    init(
        minimumUsefulDuration: TimeInterval = 0.1,
        maximumUsefulDuration: TimeInterval = 301,
        fileManager: FileManager = .default
    ) {
        self.minimumUsefulDuration = minimumUsefulDuration
        self.maximumUsefulDuration = maximumUsefulDuration
        self.fileManager = fileManager
    }

    func validateAudio(at url: URL) -> AudioValidationResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .invalid(.missing)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            return .invalid(.empty)
        }

        guard let audioFile = try? AVAudioFile(forReading: url),
              audioFile.fileFormat.sampleRate > 0 else {
            return .invalid(.unreadableFormat)
        }

        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        guard duration.isFinite, duration >= minimumUsefulDuration else {
            return .invalid(.tooShort(duration: max(0, duration)))
        }
        guard duration <= maximumUsefulDuration else {
            return .invalid(.tooLong(duration: duration))
        }
        return .valid(duration: duration)
    }
}

enum MissingWhisperDependency: Equatable, Sendable {
    case binary
    case model
}

struct ResolvedWhisperDependencies: Equatable, Sendable {
    let binaryURL: URL
    let modelURL: URL
}

enum WhisperDependencyResolution: Equatable, Sendable {
    case resolved(ResolvedWhisperDependencies)
    case missing(MissingWhisperDependency)
}

protocol WhisperDependencyResolving: Sendable {
    func resolveDependencies() -> WhisperDependencyResolution
}

protocol WhisperDependencyPreflighting: Sendable {
    func preflightDependencies() async -> TalkTextDependencyPreflightResult
}

extension TalkTextDependencyResolver: WhisperDependencyPreflighting {
    func preflightDependencies() async -> TalkTextDependencyPreflightResult {
        await Task.detached(priority: .utility) {
            preflight()
        }.value
    }
}

enum TranscriptionOutcome: Equatable, Sendable {
    case success(String)
    case noSpeech
    case missingDependency(MissingWhisperDependency)
    case invalidAudio(AudioValidationFailure)
    case launchFailed(ProcessDiagnostic)
    case processFailed(ProcessDiagnostic)
    case timedOut(ProcessDiagnostic)
    case cancelled(ProcessDiagnostic)
}

protocol WhisperTranscribing: Sendable {
    func transcribe(audioURL: URL) async -> TranscriptionOutcome
    func terminateActiveTranscriptions()
}

extension WhisperTranscribing {
    /// Transcribers that own no external process have nothing to terminate.
    func terminateActiveTranscriptions() {}
}

struct WhisperTranscriber: WhisperTranscribing {
    let dependencyResolver: any WhisperDependencyResolving
    let audioValidator: any AudioValidating
    let processRunner: any AsyncProcessRunning
    let timeout: TimeInterval

    init(
        dependencyResolver: any WhisperDependencyResolving = TalkTextDependencyResolver(),
        audioValidator: any AudioValidating = RecordedAudioValidator(),
        processRunner: any AsyncProcessRunning = FoundationProcessRunner(),
        timeout: TimeInterval = 180
    ) {
        self.dependencyResolver = dependencyResolver
        self.audioValidator = audioValidator
        self.processRunner = processRunner
        self.timeout = timeout
    }

    func transcribe(audioURL: URL) async -> TranscriptionOutcome {
        let audioValidator = audioValidator
        let dependencyResolver = dependencyResolver
        async let audioValidation = Task.detached(priority: .utility) {
            audioValidator.validateAudio(at: audioURL)
        }.value
        async let dependencyResolution = Task.detached(priority: .utility) {
            dependencyResolver.resolveDependencies()
        }.value

        switch await audioValidation {
        case let .invalid(failure):
            return .invalidAudio(failure)
        case .valid:
            break
        }

        let dependencies: ResolvedWhisperDependencies
        switch await dependencyResolution {
        case let .missing(dependency):
            return .missingDependency(dependency)
        case let .resolved(resolvedDependencies):
            dependencies = resolvedDependencies
        }

        let command = ProcessCommand(
            executableURL: dependencies.binaryURL,
            arguments: WhisperBackendContract.productionArguments(
                modelURL: dependencies.modelURL,
                audioURL: audioURL
            )
        )

        let result = await processRunner.run(command, timeout: timeout)
        switch result {
        case let .launchFailed(diagnostic):
            return .launchFailed(diagnostic)
        case let .timedOut(diagnostic):
            return .timedOut(diagnostic)
        case let .cancelled(diagnostic):
            return .cancelled(diagnostic)
        case let .completed(diagnostic):
            guard diagnostic.exitedSuccessfully else {
                return .processFailed(diagnostic)
            }
            guard let output = diagnostic.standardOutputString else {
                return .processFailed(diagnostic)
            }

            let cleaned = TranscriptOutputClassifier.clean(output)
            return cleaned.isEmpty ? .noSpeech : .success(cleaned)
        }
    }

    func terminateActiveTranscriptions() {
        processRunner.terminateActiveProcesses()
    }
}

enum TranscriptOutputClassifier {
    static func clean(_ output: String) -> String {
        output
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(blank audio)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
