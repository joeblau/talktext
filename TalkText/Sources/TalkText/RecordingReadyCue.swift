import Foundation

@MainActor
protocol RecordingReadyCuePlaying: AnyObject {
    func play() async
    func stop()
}

/// The menu toggle writes this key through `@AppStorage`; players read it at
/// play time so a change applies to the very next recording.
enum RecordingCuePreference {
    static let defaultsKey = "TalkTextPlaysRecordingCues"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Plays the complete ready cue before microphone capture begins.
@MainActor
final class SystemRecordingReadyCuePlayer: RecordingReadyCuePlaying {
    private let audio = RecordingCueAudio(ascending: true)
    private let isEnabled: @MainActor () -> Bool

    init(isEnabled: @escaping @MainActor () -> Bool = { RecordingCuePreference.isEnabled() }) {
        self.isEnabled = isEnabled
    }

    func play() async {
        guard isEnabled() else { return }
        await audio.play()
    }

    func stop() {
        audio.stop()
    }
}
