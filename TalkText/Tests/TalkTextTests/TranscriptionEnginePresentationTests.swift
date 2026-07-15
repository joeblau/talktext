import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TranscriptionEnginePresentationTests: XCTestCase {
    func testEveryTranscriptionOutcomeMapsToDistinctActionablePresentation() {
        let exitFailure = ProcessDiagnostic(
            terminationStatus: 12,
            terminationReason: .exit,
            standardError: Data("not user visible".utf8)
        )
        let signalFailure = ProcessDiagnostic(
            terminationStatus: SIGTERM,
            terminationReason: .uncaughtSignal
        )
        let cases: [(TranscriptionOutcome, TranscriptionEngine.State, String)] = [
            (.success("text"), .delivering, "Delivering"),
            (.noSpeech, .idle, "No speech detected"),
            (.missingDependency(.binary), .failed, "whisper-cli is missing"),
            (.missingDependency(.model), .failed, "model is missing"),
            (.invalidAudio(.missing), .failed, "recording is empty"),
            (.invalidAudio(.empty), .failed, "recording is empty"),
            (.invalidAudio(.unreadableFormat), .failed, "recording is unreadable"),
            (.invalidAudio(.tooShort(duration: 0.01)), .failed, "too short"),
            (.invalidAudio(.tooLong(duration: 999)), .failed, "duration limit"),
            (
                .launchFailed(
                    ProcessDiagnostic(
                        launchErrorDomain: NSPOSIXErrorDomain,
                        launchErrorCode: Int(ENOENT)
                    )
                ),
                .failed,
                "start whisper-cli"
            ),
            (.processFailed(exitFailure), .failed, "exit 12"),
            (.processFailed(signalFailure), .failed, "interrupted"),
            (.timedOut(signalFailure), .failed, "timed out"),
            (.cancelled(signalFailure), .failed, "cancelled"),
        ]

        for (outcome, expectedState, expectedText) in cases {
            let presentation = TranscriptionEngine.presentation(for: outcome)
            XCTAssertEqual(presentation.state, expectedState)
            XCTAssertTrue(
                presentation.statusText.localizedCaseInsensitiveContains(expectedText),
                "Missing \(expectedText) in \(presentation.statusText)"
            )
        }
    }

    func testNoSpeechMessageIsReservedForSuccessfulEmptyOutput() {
        let diagnostic = ProcessDiagnostic(
            terminationStatus: 1,
            terminationReason: .exit
        )
        let failures: [TranscriptionOutcome] = [
            .missingDependency(.binary),
            .missingDependency(.model),
            .invalidAudio(.empty),
            .launchFailed(ProcessDiagnostic(launchErrorDomain: NSPOSIXErrorDomain, launchErrorCode: 2)),
            .processFailed(diagnostic),
            .timedOut(diagnostic),
            .cancelled(diagnostic),
        ]

        XCTAssertTrue(
            TranscriptionEngine.presentation(for: .noSpeech)
                .statusText.contains("No speech detected")
        )
        for failure in failures {
            XCTAssertFalse(
                TranscriptionEngine.presentation(for: failure)
                    .statusText.contains("No speech detected")
            )
        }
    }

    func testEveryDeliveryOutcomeMapsFinalResultRatherThanScheduledWork() {
        let manualReasons: [ManualPasteReason] = [
            .noSessionTarget,
            .targetExited,
            .targetIdentityChanged,
            .targetHasNoWindow,
            .targetCouldNotBeVerified,
            .eventPermissionDenied,
            .activationFailed,
            .eventPostFailed,
        ]

        XCTAssertEqual(
            TranscriptionEngine.presentation(for: .inserted).state,
            .idle
        )
        XCTAssertEqual(
            TranscriptionEngine.presentation(for: .pasted(restoration: .restored)).state,
            .idle
        )
        XCTAssertEqual(
            TranscriptionEngine.presentation(
                for: .pasted(restoration: .skippedBecauseClipboardChanged)
            ).state,
            .idle
        )
        XCTAssertEqual(
            TranscriptionEngine.presentation(
                for: .pasted(restoration: .failed(.writeFailed))
            ).state,
            .failed
        )

        for reason in manualReasons {
            let presentation = TranscriptionEngine.presentation(
                for: .copiedForManualPaste(reason)
            )
            XCTAssertEqual(presentation.state, .failed)
            XCTAssertTrue(presentation.statusText.contains("Copied"))
            XCTAssertTrue(presentation.statusText.localizedCaseInsensitiveContains("paste"))
        }

        let writeFailure = DeliveryOutcome.failed(
            .pasteboardWriteFailed(.writeFailed, restoration: .restored)
        )
        XCTAssertEqual(
            TranscriptionEngine.presentation(for: writeFailure).state,
            .failed
        )
        XCTAssertEqual(
            TranscriptionEngine.presentation(for: .cancelled(restoration: nil)).state,
            .failed
        )
    }
}
