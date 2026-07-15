import Foundation

extension TranscriptionEngine {
    static func preflightFailureCategory(
        _ failure: TalkTextDependencyPreflightFailure
    ) -> String {
        switch failure {
        case .invalidOverride: "invalid-override"
        case .missingBinary: "missing-binary"
        case .missingModel: "missing-model"
        case .invalidModel: "invalid-model"
        case .backendProbeFailed: "backend-probe-failed"
        case .backendMissingOptions: "backend-missing-options"
        case .backendVersionUnreported: "backend-version-unreported"
        case .unsupportedBackendVersion: "unsupported-backend-version"
        }
    }

    static func presentation(for outcome: TranscriptionOutcome) -> Presentation {
        switch outcome {
        case .success:
            Presentation(state: .delivering, statusText: "Delivering transcription…")
        case .noSpeech:
            Presentation(
                state: .idle,
                statusText: "No speech detected. Press Ctrl+Space to record"
            )
        case let .missingDependency(dependency):
            switch dependency {
            case .binary:
                Presentation(
                    state: .failed,
                    statusText: "whisper-cli is missing. Run setup.sh, then try again."
                )
            case .model:
                Presentation(
                    state: .failed,
                    statusText: "The Whisper model is missing. Run setup.sh to install it."
                )
            }
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
        case .launchFailed:
            Presentation(
                state: .failed,
                statusText: "Couldn’t start whisper-cli. Run setup.sh and try again."
            )
        case let .processFailed(diagnostic):
            if diagnostic.terminationReason == .uncaughtSignal {
                Presentation(
                    state: .failed,
                    statusText: "Transcription was interrupted by the system. Please try again."
                )
            } else {
                Presentation(
                    state: .failed,
                    statusText: "Transcription failed (exit \(diagnostic.terminationStatus ?? -1)). Please try again."
                )
            }
        case .timedOut:
            Presentation(
                state: .failed,
                statusText: "Transcription timed out. Try a shorter recording."
            )
        case .cancelled:
            Presentation(
                state: .failed,
                statusText: "Transcription was cancelled. Press Ctrl+Space to try again."
            )
        }
    }

    static func presentation(for outcome: DeliveryOutcome) -> Presentation {
        switch outcome {
        case .inserted:
            Presentation(state: .idle, statusText: "Inserted! Press Ctrl+Space to record")
        case let .pasted(restoration):
            switch restoration {
            case .restored:
                Presentation(state: .idle, statusText: "Pasted! Press Ctrl+Space to record")
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
                statusText: "Delivery was cancelled. Press Ctrl+Space to try again."
            )
        }
    }
}
