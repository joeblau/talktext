import Foundation

extension TranscriptionEngine {
    static func presentation(
        for failure: TalkTextDependencyPreflightFailure
    ) -> Presentation {
        Presentation(state: .failed, statusText: failure.userMessage, modelRecovery: failure == .unsupportedHardware ? nil : .setup)
    }

    static func preflightFailureCategory(_ failure: TalkTextDependencyPreflightFailure) -> String {
        switch failure {
        case .invalidOverride: "invalid-override"
        case .missingModel: "missing-model"
        case .invalidModel: "invalid-model"
        case .modelLoadFailed: "model-load-failed"
        case .unsupportedHardware: "unsupported-hardware"
        }
    }

    static func presentation(for outcome: TranscriptionOutcome) -> Presentation {
        switch outcome {
        case .success:
            Presentation(state: .delivering, statusText: "Delivering transcription…")
        case .noSpeech:
            Presentation(
                state: .idle,
                statusText: "No speech detected. Hold Right Option to record, double-tap to lock"
            )
        case let .modelUnavailable(failure):
            presentation(for: failure)
        case let .invalidAudio(reason):
            switch reason {
            case .missing, .empty:
                Presentation(
                    state: .failed,
                    statusText: "The recording is empty. Check the microphone and try again."
                )
            case .unreadableFormat:
                Presentation(
                    state: .failed,
                    statusText: "The recording is unreadable. Check the input device and try again."
                )
            case .tooShort:
                Presentation(
                    state: .failed,
                    statusText: "The recording was too short to transcribe. Please try again."
                )
            case .tooLong:
                Presentation(
                    state: .failed,
                    statusText: "The recording exceeded the safe duration limit. Please try again."
                )
            }
        case .inferenceFailed:
            Presentation(state: .failed, statusText: "Parakeet transcription failed. Please try again.")
        case .cancelled:
            Presentation(state: .failed, statusText: "Transcription was cancelled. Hold Right Option to try again.")
        }
    }

    static func presentation(for outcome: DeliveryOutcome) -> Presentation {
        switch outcome {
        case .inserted:
            Presentation(state: .idle, statusText: "Inserted! Hold Right Option to record, double-tap to lock")
        case let .pasted(restoration):
            switch restoration {
            case .restored:
                Presentation(state: .idle, statusText: "Pasted! Hold Right Option to record, double-tap to lock")
            case .skippedBecauseClipboardChanged:
                Presentation(
                    state: .idle,
                    statusText: "Pasted. Clipboard changed, so it was left untouched."
                )
            case .failed:
                Presentation(
                    state: .failed,
                    statusText: "Pasted, but the previous clipboard could not be restored."
                )
            }
        case let .copiedForManualPaste(reason):
            switch reason {
            case .noSessionTarget:
                Presentation(
                    state: .failed,
                    statusText: "Copied. No target app was captured; paste manually."
                )
            case .targetExited, .targetIdentityChanged:
                Presentation(
                    state: .failed,
                    statusText: "Copied. The original target app changed or quit; paste manually."
                )
            case .targetHasNoWindow:
                Presentation(
                    state: .failed,
                    statusText: "Copied. The target app has no open window; paste manually."
                )
            case .targetCouldNotBeVerified, .eventPermissionDenied:
                Presentation(
                    state: .failed,
                    statusText: "Copied. Enable Accessibility, then paste manually."
                )
            case .activationFailed:
                Presentation(
                    state: .failed,
                    statusText: "Copied. The original target could not be activated; paste manually."
                )
            case .eventPostFailed:
                Presentation(
                    state: .failed,
                    statusText: "Copied, but automatic paste failed. Paste manually."
                )
            case .liveDraftChanged:
                Presentation(state: .failed, statusText: "Copied. The live text could not be safely replaced; paste manually.")
            }
        case .failed(.pasteboardSnapshotFailed):
            Presentation(
                state: .failed,
                statusText: "Couldn’t safely preserve the clipboard, so delivery was stopped."
            )
        case .failed(.pasteboardWriteFailed):
            Presentation(
                state: .failed,
                statusText: "Couldn’t copy or paste the transcription. Please try again."
            )
        case .cancelled:
            Presentation(
                state: .failed,
                statusText: "Delivery was cancelled. Hold Right Option to try again."
            )
        }
    }
}
