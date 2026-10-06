@MainActor
protocol RecordingStoppedCuePlaying: AnyObject {
    func play()
    func stop()
}

/// Plays after the microphone closes without delaying final transcription.
@MainActor
final class SystemRecordingStoppedCuePlayer: RecordingStoppedCuePlaying {
    private let audio = RecordingCueAudio(ascending: false)
    private let isEnabled: @MainActor () -> Bool
    private var task: Task<Void, Never>?

    init(isEnabled: @escaping @MainActor () -> Bool = { RecordingCuePreference.isEnabled() }) {
        self.isEnabled = isEnabled
    }

    func play() {
        task?.cancel()
        guard isEnabled() else { return }
        task = Task { await audio.play() }
    }

    func stop() {
        task?.cancel()
        task = nil
        audio.stop()
    }
}
