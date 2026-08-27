@preconcurrency import AVFoundation
import AppKit
import Foundation
import os

private let recordingFileStoreLog = OSLog(
    subsystem: AppIdentity.bundleIdentifier,
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
    /// Loudest sample captured so far in dBFS, or `-.infinity` before any audio
    /// arrives. The engine uses this to tell silence apart from speech instead
    /// of trusting Whisper, which hallucinates words for silent input.
    var peakLevel: Float { get }
    /// The input the session actually opened, for status text and logging.
    var inputDeviceName: String { get }
    /// Opens the selected microphone and returns only after input buffers arrive.
    /// Warm-up audio is discarded so a ready cue can play after a slow Bluetooth
    /// route has settled without becoming part of the recording.
    func prepare() async -> Bool
    /// Enables file capture and returns only after a post-cue buffer reaches the
    /// WAV. `AVAudioEngine.start()` alone is not a readiness guarantee on macOS.
    func start(maximumDuration: TimeInterval) async -> Bool
    func stop() async -> RecorderStopOutcome
    func cancel()
}

enum AudioRecorderCreationError: Error, Equatable, Sendable {
    case noInputDevice
    case inputDeviceUnusable
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
    private let inputResolver: any AudioInputResolving

    init(inputResolver: any AudioInputResolving) {
        self.inputResolver = inputResolver
    }

    func makeRecorder(
        at url: URL,
        eventHandler: @escaping @MainActor (RecorderEvent) -> Void
    ) throws -> any AudioRecording {
        try SystemAudioRecorder(
            url: url,
            inputResolver: inputResolver,
            eventHandler: eventHandler
        )
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
