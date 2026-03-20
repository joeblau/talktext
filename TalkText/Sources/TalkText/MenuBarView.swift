import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(engine.statusText)
                    .font(.caption)
            }

            Divider()

            Button(recordButtonTitle) {
                engine.toggleRecording()
            }
            .keyboardShortcut(.space, modifiers: .control)
            .disabled(engine.state == .transcribing)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    private var statusColor: Color {
        switch engine.state {
        case .idle: return .green
        case .recording: return .red
        case .transcribing: return .yellow
        }
    }

    private var recordButtonTitle: String {
        switch engine.state {
        case .idle: return "Start Recording"
        case .recording: return "Stop & Transcribe"
        case .transcribing: return "Transcribing..."
        }
    }
}
