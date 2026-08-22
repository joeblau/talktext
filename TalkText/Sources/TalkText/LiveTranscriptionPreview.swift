import Foundation

/// Owns the best-effort draft loop independently from the canonical final
/// transcription. Preview failures never stop recording or deliver partial text.
@MainActor
final class LiveTranscriptionPreview {
    private let recordingFileStore: any RecordingFileStoring
    private let recordingSnapshotter: any ActiveRecordingSnapshotting
    private let transcriber: any WhisperTranscribing

    private var currentPreviewURL: URL?
    private var task: Task<Void, Never>?

    init(
        recordingFileStore: any RecordingFileStoring,
        recordingSnapshotter: any ActiveRecordingSnapshotting,
        transcriber: any WhisperTranscribing
    ) {
        self.recordingFileStore = recordingFileStore
        self.recordingSnapshotter = recordingSnapshotter
        self.transcriber = transcriber
    }

    func start(
        recordingURL: URL,
        interval: TimeInterval,
        receiveTranscript: @escaping @MainActor (String) -> Void
    ) {
        cleanup()
        let boundedInterval = max(0.1, interval)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(boundedInterval))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if let transcript = await self.refresh(recordingURL: recordingURL) {
                    receiveTranscript(transcript)
                }
            }
        }
    }

    /// Cancels the current Whisper pass and returns the task so the final flow
    /// can wait until its subprocess and snapshot have been cleaned up.
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

        let snapshotCreated = await recordingSnapshotter.createSnapshot(
            from: recordingURL,
            at: previewURL
        )
        guard !Task.isCancelled, snapshotCreated else {
            removeCurrentPreview(ifMatching: previewURL)
            return nil
        }

        let outcome = await transcriber.transcribe(audioURL: previewURL)
        removeCurrentPreview(ifMatching: previewURL)
        guard !Task.isCancelled, case let .success(text) = outcome else {
            return nil
        }
        return text
    }

    private func removeCurrentPreview(ifMatching previewURL: URL? = nil) {
        guard let currentPreviewURL,
              previewURL == nil || previewURL == currentPreviewURL else {
            return
        }
        self.currentPreviewURL = nil
        try? recordingFileStore.removeRecording(at: currentPreviewURL)
    }
}
