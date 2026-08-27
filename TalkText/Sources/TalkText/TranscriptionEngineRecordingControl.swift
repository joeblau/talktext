import os

private let recordingControlLogger = Logger(
    subsystem: AppIdentity.bundleIdentifier,
    category: "recording-control"
)

extension TranscriptionEngine {
    func toggleRecording() {
        if state == .recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        switch state {
        case .idle, .failed:
            startRecordingFlow()
        case .starting where currentSessionIdentifier == nil:
            // A launch-time dependency check is in flight. Preserve the user's
            // intent and await the same cached task instead of dropping input.
            startRecordingFlow()
        case .requestingPermission, .starting, .recording, .stopping, .transcribing, .delivering:
            recordingControlLogger.debug("Ignored recording start while engine is active")
        }
    }

    func stopRecording() {
        switch state {
        case .recording:
            stopRecordingFlow()
        case .requestingPermission:
            cancelPendingRecordingStart()
        case .starting where currentSessionIdentifier != nil:
            cancelPendingRecordingStart()
        case .idle, .failed, .starting, .stopping, .transcribing, .delivering:
            recordingControlLogger.debug(
                "Ignored recording stop without an active recording intent"
            )
        }
    }
}
