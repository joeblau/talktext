import SwiftUI

@main
struct TalkTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.transcriptionEngine)
                .environmentObject(appDelegate.hotKeyController)
                .environmentObject(appDelegate.audioInputSelection)
        } label: {
            MenuBarIcon()
                .environmentObject(appDelegate.transcriptionEngine)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var engine: TranscriptionEngine

    var body: some View {
        Image(systemName: engine.state == .recording ? "mic.fill" : "waveform")
            .accessibilityLabel(engine.state == .recording ? "Recording" : "TalkText")
    }
}
