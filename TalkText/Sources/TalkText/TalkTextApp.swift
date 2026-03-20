import SwiftUI

@main
struct TalkTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.transcriptionEngine)
        } label: {
            MenuBarIcon()
                .environmentObject(appDelegate.transcriptionEngine)
        }
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var engine: TranscriptionEngine

    var body: some View {
        switch engine.state {
        case .idle:
            Image(systemName: "waveform")
        case .recording:
            Image(systemName: "record.circle")
                .symbolRenderingMode(.multicolor)
        case .transcribing:
            Image(systemName: "ellipsis.circle")
        }
    }
}
