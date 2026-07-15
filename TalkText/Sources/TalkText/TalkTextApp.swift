import SwiftUI

@main
struct TalkTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.transcriptionEngine)
                .environmentObject(appDelegate.hotKeyController)
        } label: {
            MenuBarIcon()
                .environmentObject(appDelegate.transcriptionEngine)
                .environmentObject(appDelegate.hotKeyController)
        }
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var hotKeyController: HotKeyController

    var body: some View {
        switch engine.state {
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        case .idle:
            if hotKeyController.availability.isRegistered {
                Image(systemName: "waveform")
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        case .recording:
            Image(systemName: "record.circle")
                .symbolRenderingMode(.multicolor)
        case .requestingPermission, .starting, .stopping, .transcribing, .delivering:
            Image(systemName: "ellipsis.circle")
        }
    }
}
