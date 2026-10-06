import Foundation
import os

let liveTextLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "live-text")

/// Owns the best-effort draft loop independently from the canonical final
/// transcription. Preview failures never stop recording or deliver partial text.
/// Each draft is a full pass over the audio so far: Parakeet decodes 30 seconds
/// in about 0.2 seconds, so drafts appear within the first spoken words and
/// read the same as the final text rather than lagging a streaming window.
@MainActor
final class LiveTranscriptionPreview {
    private let recordingFileStore: any RecordingFileStoring
    private let recordingSnapshotter: any ActiveRecordingSnapshotting
    private let transcriber: any SpeechTranscribing

    private var currentPreviewURL: URL?
    private var task: Task<Void, Never>?

    init(
        recordingFileStore: any RecordingFileStoring,
        recordingSnapshotter: any ActiveRecordingSnapshotting,
        transcriber: any SpeechTranscribing
    ) {
        self.recordingFileStore = recordingFileStore
        self.recordingSnapshotter = recordingSnapshotter
        self.transcriber = transcriber
    }

    func start(
        recordingURL: URL,
        interval: TimeInterval,
        receiveTranscript: @escaping @MainActor (String) async -> Void
    ) {
        cleanup()
        let boundedInterval = max(0.1, interval)
        task = Task { @MainActor [weak self] in
            var lastTranscript: String?
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(boundedInterval))
                } catch {
                    break
                }
                guard let self else {
                    break
                }
                if let transcript = await self.refresh(recordingURL: recordingURL), transcript != lastTranscript {
                    liveTextLogger.debug("Live draft ready; characters: \(transcript.count, privacy: .public)")
                    lastTranscript = transcript
                    await receiveTranscript(transcript)
                }
            }
        }
    }

    /// Cancels the draft pass so the final flow can wait for it to wind down.
    func stop() -> Task<Void, Never>? {
        let currentTask = task
        task = nil
        currentTask?.cancel()
        return currentTask
    }

    func cleanup() {
        task?.cancel()
        task = nil
        removeCurrentPreview()
    }

    private func refresh(recordingURL: URL) async -> String? {
        guard !Task.isCancelled else {
            return nil
        }

        let previewURL: URL
        do {
            previewURL = try recordingFileStore.allocateRecordingURL()
        } catch {
            return nil
        }
        currentPreviewURL = previewURL
        // The snapshot writer may finish an atomic write after cleanup removed
        // its destination. Each pass must clean its own URL on completion, even
        // if a newer preview session now owns currentPreviewURL.
        defer {
            if currentPreviewURL == previewURL { currentPreviewURL = nil }
            try? recordingFileStore.removeRecording(at: previewURL)
        }

        let snapshotCreated = await recordingSnapshotter.createSnapshot(
            from: recordingURL,
            at: previewURL
        )
        guard !Task.isCancelled, snapshotCreated else {
            if !Task.isCancelled { liveTextLogger.debug("Live snapshot unavailable") }
            return nil
        }

        let outcome = await transcriber.transcribe(audioURL: previewURL)
        guard !Task.isCancelled, case let .success(text) = outcome else {
            return nil
        }
        return text
    }

    private func removeCurrentPreview() {
        guard let currentPreviewURL else {
            return
        }
        self.currentPreviewURL = nil
        try? recordingFileStore.removeRecording(at: currentPreviewURL)
    }
}
