import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let transcriptionEngine: TranscriptionEngine
    let hotKeyController: HotKeyController

    override convenience init() {
        self.init(
            transcriptionEngine: TranscriptionEngine(),
            hotKeyController: HotKeyController()
        )
    }

    init(
        transcriptionEngine: TranscriptionEngine,
        hotKeyController: HotKeyController
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.hotKeyController = hotKeyController
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKeyController.register { [weak self] in
            self?.transcriptionEngine.toggleRecording()
        }
        transcriptionEngine.prepareDependencies()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController.unregister()
        // This call is intentionally synchronous: it does not return until an
        // active whisper-cli child has been reaped.
        transcriptionEngine.cleanup()
    }
}
