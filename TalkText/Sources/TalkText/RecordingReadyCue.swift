import AppKit
import os

private let recordingReadyCueLogger = Logger(
    subsystem: AppIdentity.bundleIdentifier,
    category: "recording-ready-cue"
)

@MainActor
protocol RecordingReadyCuePlaying: AnyObject {
    func play() async
    func stop()
}

/// Plays a short, quiet system chime before microphone capture begins. Waiting
/// for playback to finish prevents TalkText from transcribing its own cue.
@MainActor
final class SystemRecordingReadyCuePlayer: RecordingReadyCuePlaying {
    private let sound: NSSound?

    init(sound: NSSound? = NSSound(named: NSSound.Name("Tink"))) {
        self.sound = sound
        sound?.volume = 0.2
    }

    func play() async {
        guard let sound else {
            return
        }

        sound.stop()
        guard sound.play() else {
            recordingReadyCueLogger.error("Recording ready cue could not play")
            return
        }
        recordingReadyCueLogger.notice("Recording ready cue played")

        let duration = min(max(sound.duration, 0), 0.25)
        do {
            try await Task.sleep(for: .seconds(duration))
        } catch {
            sound.stop()
            return
        }
        sound.stop()
    }

    func stop() {
        sound?.stop()
    }
}
