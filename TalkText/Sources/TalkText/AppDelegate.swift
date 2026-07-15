import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let transcriptionEngine = TranscriptionEngine()
    let hotKeyController = HotKeyController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKeyController.register { [weak self] in
            self?.transcriptionEngine.toggleRecording()
        }
        transcriptionEngine.prepareDependencies()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController.unregister()
        transcriptionEngine.cleanup()
    }
}
