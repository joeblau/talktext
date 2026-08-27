import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var hotKeyController: HotKeyController
    @EnvironmentObject var audioInputSelection: AudioInputSelection

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
                Button("Retry Right Option Listener") {
                    hotKeyController.retry()
                }
            }

            if let recovery = engine.whisperRecovery {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recovery.message)
                        .font(.caption)
                    Text(recovery.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Button(recovery.copyButtonTitle) {
                        copyToPasteboard(recovery.command)
                    }
                    Button("Check Whisper Again") {
                        engine.prepareDependencies(forceRefresh: true)
                    }
                }
            }

            Divider()

            inputDevicePicker

            Divider()

            Button(recordButtonTitle) {
                engine.toggleRecording()
            }
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

    private var inputDevicePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Input", selection: inputSelectionBinding) {
                Text(systemDefaultTitle).tag(AudioInputPreference.systemDefault)
                ForEach(audioInputSelection.devices) { device in
                    Text(device.name).tag(AudioInputPreference.device(uid: device.uid))
                }
            }
            .pickerStyle(.menu)
            .disabled(!engine.isInteractive)

            if case let .device(uid) = audioInputSelection.preference,
               !audioInputSelection.devices.contains(where: { $0.uid == uid }) {
                Text("That input is disconnected. Recording uses the system default until it returns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            audioInputSelection.refreshDevices()
        }
    }

    private var systemDefaultTitle: String {
        guard case .systemDefault = audioInputSelection.preference else {
            return "System Default"
        }
        return audioInputSelection.selectionSummary
    }

    private var inputSelectionBinding: Binding<AudioInputPreference> {
        Binding(
            get: { audioInputSelection.preference },
            set: { audioInputSelection.select($0) }
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
