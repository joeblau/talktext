import Foundation

extension TranscriptionEngine {
    convenience init(inputSelection: AudioInputSelection) {
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

        ParakeetTranscriber.configureRuntime()
        let transcriber = ParakeetTranscriber()
        self.init(
            permissionProvider: SystemMicrophonePermissionProvider(),
            recorderFactory: SystemAudioRecorderFactory(inputResolver: inputSelection),
            recordingFileStore: recordingFileStore,
            recordingSnapshotter: ActiveWAVRecordingSnapshotter(),
            dependencyPreflight: transcriber,
            transcriber: transcriber,
            textDelivery: TextDeliveryService(),
            applicationBundleIdentifier: Bundle.main.bundleIdentifier,
            startupPresentation: startupPresentation
        )
    }
}

@MainActor
final class UnavailableRecordingFileStore: RecordingFileStoring {
    func allocateRecordingURL() throws -> URL {
        throw RecordingFileStoreError.unableToAllocateRecording
    }

    func removeRecording(at url: URL) throws {}
    func removeStaleOwnedFiles(olderThan age: TimeInterval) throws {}
    func cleanupInstance() throws {}
}
