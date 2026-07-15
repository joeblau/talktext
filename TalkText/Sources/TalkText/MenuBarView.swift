import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var hotKeyController: HotKeyController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(engine.statusText)
                    .font(.caption)
            }

            if let recoveryMessage = hotKeyController.availability.recoveryMessage {
                HStack(alignment: .top) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    Text(recoveryMessage)
                        .font(.caption)
                }
                Button("Retry Ctrl+Space") {
                    hotKeyController.retry()
                }
            }

            Divider()

            Button(recordButtonTitle) {
                engine.toggleRecording()
            }
            .keyboardShortcut(.space, modifiers: .control)
            .disabled(!recordButtonEnabled)

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
        case .requestingPermission, .starting, .stopping, .transcribing, .delivering:
            return .yellow
        case .failed: return .red
        }
    }

    private var recordButtonTitle: String {
        switch engine.state {
        case .idle: return "Start Recording"
        case .failed: return "Try Again"
        case .requestingPermission: return "Waiting for Permission…"
        case .starting: return "Starting…"
        case .recording: return "Stop & Transcribe"
        case .stopping: return "Finalizing…"
        case .transcribing: return "Transcribing…"
        case .delivering: return "Delivering…"
        }
    }

    private var recordButtonEnabled: Bool {
        switch engine.state {
        case .idle, .failed, .recording:
            true
        case .requestingPermission, .starting, .stopping, .transcribing, .delivering:
            false
        }
    }
}
