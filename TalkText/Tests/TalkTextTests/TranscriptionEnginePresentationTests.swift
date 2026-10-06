import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TranscriptionEnginePresentationTests: XCTestCase {
    func testModelFailuresOfferSetupRecoveryWithoutAnExternalBackendInstall() {
        let failures: [TalkTextDependencyPreflightFailure] = [
            .missingModel(searchedPaths: []),
            .invalidModel(path: "/fixture", reason: "incomplete"),
            .modelLoadFailed(TranscriptionDiagnostic(domain: "CoreML", code: 1)),
        ]
        for failure in failures {
            let presentation = TranscriptionEngine.presentation(for: failure)
            XCTAssertEqual(presentation.state, .failed)
            XCTAssertEqual(presentation.modelRecovery, .setup)
            XCTAssertEqual(presentation.modelRecovery?.command, "./setup.sh")
            XCTAssertTrue(presentation.statusText.contains("Parakeet"))
        }
    }

    func testNoSpeechMessageIsReservedForSuccessfulEmptyOutput() {
        let failures: [TranscriptionOutcome] = [
            .modelUnavailable(.missingModel(searchedPaths: [])),
            .invalidAudio(.empty),
            .inferenceFailed(TranscriptionDiagnostic(domain: "CoreML", code: 1)),
            .cancelled,
        ]
        XCTAssertTrue(TranscriptionEngine.presentation(for: .noSpeech).statusText.contains("No speech detected"))
        for failure in failures {
            XCTAssertEqual(TranscriptionEngine.presentation(for: failure).state, .failed)
            XCTAssertFalse(TranscriptionEngine.presentation(for: failure).statusText.contains("No speech detected"))
        }
    }

    func testUnsupportedHardwareExplainsRequirementWithoutOfferingModelSetup() {
        let presentation = TranscriptionEngine.presentation(for: TalkTextDependencyPreflightFailure.unsupportedHardware)
        XCTAssertEqual(presentation.state, .failed)
        XCTAssertNil(presentation.modelRecovery)
        XCTAssertTrue(presentation.statusText.contains("Apple Silicon"))
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
            .liveDraftChanged,
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
        let snapshotFailure = DeliveryOutcome.failed(
            .pasteboardSnapshotFailed(.representationReadFailed(type: "public.rtf"))
        )
        let snapshotPresentation = TranscriptionEngine.presentation(for: snapshotFailure)
        XCTAssertEqual(snapshotPresentation.state, .failed)
        XCTAssertTrue(snapshotPresentation.statusText.contains("delivery was stopped"))
        XCTAssertEqual(
            TranscriptionEngine.presentation(for: .cancelled(restoration: nil)).state,
            .failed
        )
    }
}
