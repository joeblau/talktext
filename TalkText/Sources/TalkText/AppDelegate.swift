import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let transcriptionEngine: TranscriptionEngine
    let hotKeyController: HotKeyController
    let audioInputSelection: AudioInputSelection
    private var engineStateObservation: AnyCancellable?

    override convenience init() {
        let audioInputSelection = AudioInputSelection()
        self.init(
            transcriptionEngine: TranscriptionEngine(inputSelection: audioInputSelection),
            hotKeyController: HotKeyController(),
            audioInputSelection: audioInputSelection
        )
    }

    init(
        transcriptionEngine: TranscriptionEngine,
        hotKeyController: HotKeyController,
        audioInputSelection: AudioInputSelection = AudioInputSelection()
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.hotKeyController = hotKeyController
        self.audioInputSelection = audioInputSelection
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKeyController.register { [weak self] intent in
            switch intent {
            case .start:
                self?.transcriptionEngine.startRecording()
            case .stop:
                self?.transcriptionEngine.stopRecording()
            }
        }
        engineStateObservation = transcriptionEngine.$state
            .removeDuplicates()
            .sink { [weak self] state in
                switch state {
                case .idle, .stopping, .transcribing, .delivering, .failed:
                    self?.hotKeyController.recordingSessionDidEnd()
                case .requestingPermission, .starting, .recording:
                    break
                }
            }
        transcriptionEngine.prepareDependencies()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineStateObservation?.cancel()
        engineStateObservation = nil
        hotKeyController.unregister()
        // This call is intentionally synchronous: it does not return until an
        // active transcription has been cancelled.
        transcriptionEngine.cleanup()
    }
}
