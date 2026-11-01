import Foundation
import os

let liveTextLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "live-text")

/// How much recent audio each draft re-transcribes. Earlier speech is locked in
/// at a pause so every pass stays fast no matter how long the dictation runs.
struct LiveDraftWindow: Equatable, Sendable {
    /// Audio after the locked-in text is re-transcribed in full until it grows
    /// past this length.
    var maximumDuration: TimeInterval = 30
    /// Where to look for a pause, measured from the start of unlocked audio.
    var lockSearchStart: TimeInterval = 15
    var lockSearchEnd: TimeInterval = 25
}

/// Owns the best-effort draft loop. Each draft is a full-context Parakeet pass
/// over the unlocked audio with fresh decoder state, so drafts carry final-pass
/// accuracy; a later pass may revise words an earlier draft showed. Passes run
/// back to back. Preview failures never stop recording or deliver partial text.
@MainActor
final class LiveTranscriptionPreview {
    private let recordingFileStore: any RecordingFileStoring
    private let recordingSnapshotter: any ActiveRecordingSnapshotting
    private let transcriber: any SpeechTranscribing
    private let window: LiveDraftWindow

    private var temporaryURLs: Set<URL> = []
    private var task: Task<Void, Never>?
    /// Text for audio before `lockedFrame`, which drafts no longer re-transcribe.
    private var lockedText = ""
    private var lockedFrame = 0
    private var lastSnapshotFrameCount: Int?

    init(
        recordingFileStore: any RecordingFileStoring,
        recordingSnapshotter: any ActiveRecordingSnapshotting,
        transcriber: any SpeechTranscribing,
        window: LiveDraftWindow = LiveDraftWindow()
    ) {
        self.recordingFileStore = recordingFileStore
        self.recordingSnapshotter = recordingSnapshotter
        self.transcriber = transcriber
        self.window = window
    }

    /// `minimumInterval` only spaces out passes that finish quickly; a slower
    /// pass is followed immediately by the next one.
    func start(
        recordingURL: URL,
        minimumInterval: TimeInterval,
        receiveTranscript: @escaping @MainActor (String) async -> Void
    ) {
        cleanup()
        let spacing = Duration.seconds(max(0.05, minimumInterval))
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var lastTranscript: String?
            // The first pass waits one interval so it has audio to decode.
            var nextPass = clock.now.advanced(by: spacing)
            while !Task.isCancelled {
                do { try await Task.sleep(until: nextPass, clock: clock) } catch { break }
                let passStart = clock.now
                guard let self else { break }
                if let transcript = await self.refresh(recordingURL: recordingURL),
                   !Task.isCancelled, transcript != lastTranscript {
                    liveTextLogger.debug("Live draft ready; characters: \(transcript.count, privacy: .public)")
                    lastTranscript = transcript
                    await receiveTranscript(transcript)
                }
                nextPass = passStart.advanced(by: spacing)
            }
        }
    }

    /// Cancels the draft pass so the final flow can wait for it to wind down.
    /// Locked-in text is kept for `finalTranscription(recordingURL:)`.
    func stop() -> Task<Void, Never>? {
        let currentTask = task
        task = nil
        currentTask?.cancel()
        return currentTask
    }

    func cleanup() {
        task?.cancel()
        task = nil
        lockedText = ""
        lockedFrame = 0
        lastSnapshotFrameCount = nil
        for url in temporaryURLs {
            try? recordingFileStore.removeRecording(at: url)
        }
        temporaryURLs.removeAll()
    }

    /// The complete transcript of the finished recording: locked-in text plus
    /// one full-context pass over everything after it. Short dictations never
    /// lock text, so this is a single pass over the whole recording.
    func finalTranscription(recordingURL: URL) async -> TranscriptionOutcome {
        guard lockedFrame > 0 else {
            return await transcriber.transcribe(audioURL: recordingURL)
        }
        let lockedText = lockedText
        let tail = await transcribe(from: recordingURL, startingAt: lockedFrame)
        switch tail {
        case let .success(text):
            return .success(Self.join(lockedText, text))
        case .noSpeech:
            return lockedText.isEmpty ? .noSpeech : .success(lockedText)
        case .cancelled:
            return .cancelled
        default:
            // The windowed path failed; the whole recording is still authoritative.
            return await transcriber.transcribe(audioURL: recordingURL)
        }
    }

    private func refresh(recordingURL: URL) async -> String? {
        guard !Task.isCancelled, let snapshotURL = allocateTemporaryURL() else { return nil }
        defer { removeTemporary(snapshotURL) }

        let snapshotCreated = await recordingSnapshotter.createSnapshot(from: recordingURL, at: snapshotURL)
        guard !Task.isCancelled, snapshotCreated else {
            if !Task.isCancelled { liveTextLogger.debug("Live snapshot unavailable") }
            return nil
        }

        guard let layout = await Self.layout(of: snapshotURL) else {
            // Not a readable PCM file: transcribe the snapshot whole.
            let outcome = await transcriber.transcribe(audioURL: snapshotURL)
            guard !Task.isCancelled, case let .success(text) = outcome else { return nil }
            return text
        }
        // Nothing new was recorded since the last pass.
        guard layout.frameCount != lastSnapshotFrameCount else { return nil }
        lastSnapshotFrameCount = layout.frameCount

        await lockEarlierSpeechIfNeeded(snapshotURL: snapshotURL, layout: layout)
        guard !Task.isCancelled else { return nil }

        let outcome = lockedFrame > 0
            ? await transcribe(from: snapshotURL, startingAt: lockedFrame)
            : await transcriber.transcribe(audioURL: snapshotURL)
        guard !Task.isCancelled else { return nil }
        switch outcome {
        case let .success(text):
            return Self.join(lockedText, text)
        case .noSpeech where !lockedText.isEmpty:
            return lockedText
        default:
            return nil
        }
    }

    /// Once unlocked audio outgrows the window, transcribes it up to the
    /// quietest moment in the search range and locks that text in.
    private func lockEarlierSpeechIfNeeded(snapshotURL: URL, layout: RecordingAudioWindow.Layout) async {
        let rate = layout.sampleRate
        let unlockedFrames = layout.frameCount - lockedFrame
        guard Double(unlockedFrames) > window.maximumDuration * rate else { return }

        let searchStart = lockedFrame + Int(window.lockSearchStart * rate)
        let searchEnd = min(layout.frameCount, lockedFrame + Int(window.lockSearchEnd * rate))
        guard searchStart < searchEnd,
              let cut = await Self.quietestFrame(in: snapshotURL, searching: searchStart..<searchEnd),
              let segmentURL = allocateTemporaryURL() else { return }
        defer { removeTemporary(segmentURL) }

        guard await Self.write(from: snapshotURL, frames: lockedFrame..<cut, to: segmentURL), !Task.isCancelled else {
            return
        }
        let outcome = await transcriber.transcribe(audioURL: segmentURL)
        guard !Task.isCancelled else { return }
        switch outcome {
        case let .success(text):
            lockedText = Self.join(lockedText, text)
            lockedFrame = cut
            liveTextLogger.debug("Locked live draft through frame \(cut, privacy: .public)")
        case .noSpeech:
            lockedFrame = cut
        default:
            break
        }
    }

    private func transcribe(from sourceURL: URL, startingAt frame: Int) async -> TranscriptionOutcome {
        guard let layout = await Self.layout(of: sourceURL) else { return .inferenceFailed(Self.windowFailure) }
        guard frame < layout.frameCount else { return .noSpeech }
        guard let segmentURL = allocateTemporaryURL() else { return .inferenceFailed(Self.windowFailure) }
        defer { removeTemporary(segmentURL) }
        guard await Self.write(from: sourceURL, frames: frame..<layout.frameCount, to: segmentURL) else {
            return .inferenceFailed(Self.windowFailure)
        }
        return await transcriber.transcribe(audioURL: segmentURL)
    }

    private func allocateTemporaryURL() -> URL? {
        guard let url = try? recordingFileStore.allocateRecordingURL() else { return nil }
        temporaryURLs.insert(url)
        return url
    }

    private func removeTemporary(_ url: URL) {
        temporaryURLs.remove(url)
        try? recordingFileStore.removeRecording(at: url)
    }

    private static func join(_ earlier: String, _ later: String) -> String {
        [earlier, later].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let windowFailure = TranscriptionDiagnostic(domain: "TalkText.LiveDraftWindow", code: 1)

    // File work stays off the main actor.
    private nonisolated static func layout(of url: URL) async -> RecordingAudioWindow.Layout? {
        await Task.detached(priority: .userInitiated) { RecordingAudioWindow.layout(of: url) }.value
    }

    private nonisolated static func write(from source: URL, frames: Range<Int>, to destination: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            RecordingAudioWindow.write(from: source, frames: frames, to: destination)
        }.value
    }

    private nonisolated static func quietestFrame(in source: URL, searching frames: Range<Int>) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            RecordingAudioWindow.quietestFrame(in: source, searching: frames)
        }.value
    }
}
