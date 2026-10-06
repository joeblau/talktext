import AppKit
import SwiftUI

/// Native menu items only: dictation stays at the cursor in the user's app.
struct MenuBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var hotKeyController: HotKeyController
    @EnvironmentObject var audioInputSelection: AudioInputSelection
    @AppStorage(RecordingCuePreference.defaultsKey) private var playsSoundCues = true

    var body: some View {
        Section {
            Label(statusTitle, systemImage: statusSymbol)
            if let detail = statusDetail {
                Text(detail)
            }
        }

        Divider()

        Button {
            if engine.state == .recording || engine.state == .requestingPermission
                || (engine.state == .starting && engine.currentSessionIdentifier != nil) {
                engine.stopRecording()
            } else {
                engine.startRecording()
            }
        } label: {
            Label(recordButtonTitle, systemImage: recordButtonSymbol)
        }
        .disabled(!recordButtonEnabled)

        if !hotKeyController.availability.isRegistered {
            Button { hotKeyController.retry() } label: {
                Label("Enable Right Option Shortcut", systemImage: "keyboard")
            }
        }

        if let recovery = engine.modelRecovery {
            Button { copyToPasteboard(recovery.command) } label: {
                Label(recovery.copyButtonTitle, systemImage: "doc.on.doc")
            }
            Button { engine.prepareDependencies(forceRefresh: true) } label: {
                Label("Retry Speech Model", systemImage: "arrow.clockwise")
            }
        }

        Divider()

        Picker(selection: inputSelectionBinding) {
            Text(systemDefaultTitle).tag(AudioInputPreference.systemDefault)
            if !audioInputSelection.devices.isEmpty {
                Divider()
            }
            ForEach(audioInputSelection.devices) { device in
                Text(device.name).tag(AudioInputPreference.device(uid: device.uid))
            }
            if audioInputSelection.isPreferredDeviceMissing {
                Divider()
                Text("Disconnected Device").tag(audioInputSelection.preference)
            }
        } label: {
            Label("Microphone", systemImage: "mic")
        }
        .pickerStyle(.menu)
        .disabled(!engine.isInteractive && engine.state != .recording)
        .onAppear { audioInputSelection.refreshDevices() }

        Toggle(isOn: $playsSoundCues) {
            Label("Sound Cues", systemImage: playsSoundCues ? "speaker.wave.2" : "speaker.slash")
        }

        Divider()

        Button("Quit TalkText") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusTitle: String {
        switch engine.state {
        case .idle: return "Ready"
        case .requestingPermission: return "Waiting for Microphone Access"
        case .starting: return "Starting…"
        case .recording: return "Listening…"
        case .stopping, .transcribing: return "Transcribing…"
        case .delivering: return "Inserting Text…"
        case .failed: return "Dictation Unavailable"
        }
    }

    private var statusSymbol: String {
        switch engine.state {
        case .idle: return "checkmark.circle"
        case .requestingPermission: return "lock"
        case .starting: return "hourglass"
        case .recording: return "waveform"
        case .stopping, .transcribing, .delivering: return "text.cursor"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// Idle shows the shortcut; failures show the engine's recovery advice.
    /// Transient states need no second line.
    private var statusDetail: String? {
        switch engine.state {
        case .idle: return "Hold Right Option to dictate · double-tap to lock"
        case .failed: return engine.statusText
        case .starting where engine.statusText != "Starting…": return engine.statusText
        default: return nil
        }
    }

    private var recordButtonTitle: String {
        switch engine.state {
        case .recording: return "Stop Recording"
        case .requestingPermission: return "Cancel"
        case .starting where engine.currentSessionIdentifier != nil: return "Cancel"
        case .failed: return "Try Again"
        default: return "Start Recording"
        }
    }

    private var recordButtonSymbol: String {
        switch engine.state {
        case .recording: return "stop.circle"
        case .requestingPermission, .starting: return "xmark.circle"
        case .failed: return "arrow.clockwise"
        default: return "record.circle"
        }
    }

    private var recordButtonEnabled: Bool {
        switch engine.state {
        case .idle, .failed, .recording, .starting, .requestingPermission: return true
        case .stopping, .transcribing, .delivering: return false
        }
    }

    private var systemDefaultTitle: String {
        guard case .systemDefault = audioInputSelection.preference else { return "System Default" }
        return audioInputSelection.selectionSummary
    }

    private var inputSelectionBinding: Binding<AudioInputPreference> {
        Binding(get: { audioInputSelection.preference }, set: { audioInputSelection.select($0) })
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
