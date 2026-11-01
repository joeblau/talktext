import CoreGraphics
import XCTest
@testable import TalkText

final class TranscriptConfirmationTests: XCTestCase {
    func testWordsConfirmOnlyOnceTwoPassesAgree() {
        var confirmation = TranscriptConfirmation()
        XCTAssertEqual(confirmation.update(with: "I think we should probably"), 0)
        // The boundary sits at the end of "probably": every word agrees.
        XCTAssertEqual(confirmation.update(with: "I think we should probably move the"), 26)
        XCTAssertEqual(confirmation.update(with: "I think we should probably move the meeting to Thursday"), 35)
    }

    func testARevisedWordStopsTheBoundaryAtTheRevision() {
        var confirmation = TranscriptConfirmation()
        _ = confirmation.update(with: "move the meeting to Thursday")
        XCTAssertEqual(confirmation.update(with: "move the meeting to Friday"), 19)
        XCTAssertEqual(confirmation.update(with: "move the meeting to Friday"), 26)
    }

    func testAnEarlierCorrectionMovesTheBoundaryBack() {
        var confirmation = TranscriptConfirmation()
        _ = confirmation.update(with: "ask not what your customers country")
        XCTAssertEqual(confirmation.update(with: "ask not what your customers country can"), 35)
        XCTAssertEqual(confirmation.update(with: "ask not what your country can do"), 17)
    }

    func testCaseAndTrailingPunctuationDoNotBlockAgreement() {
        var confirmation = TranscriptConfirmation()
        _ = confirmation.update(with: "and so my fellow americans")
        let text = "And so, my fellow Americans."
        XCTAssertEqual(confirmation.update(with: text), text.count)
    }

    func testEmptyAndWhitespaceDraftsConfirmNothing() {
        var confirmation = TranscriptConfirmation()
        XCTAssertEqual(confirmation.update(with: ""), 0)
        XCTAssertEqual(confirmation.update(with: "   "), 0)
    }

    func testSweepAtRestIsSolidBehindAndUniformlyFaintAhead() {
        let faint = ConfirmationSweep.unconfirmedOpacity
        // Nothing confirmed: even the first character is faint.
        XCTAssertEqual(ConfirmationSweep.opacity(forCharacterAt: 0, boundary: 0), faint)
        // Fully confirmed: the last character is fully solid.
        XCTAssertEqual(ConfirmationSweep.opacity(forCharacterAt: 9, boundary: 10), 1)
        XCTAssertEqual(ConfirmationSweep.opacity(forCharacterAt: 10, boundary: 10), faint)
    }

    func testMovingSweepHasASoftEdgeThatSettlesCrisp() {
        let softness = ConfirmationSweep.softness(atProgress: 0.5)
        XCTAssertEqual(softness, ConfirmationSweep.gradientWidth, accuracy: 0.001)
        XCTAssertEqual(ConfirmationSweep.softness(atProgress: 0), 0, accuracy: 0.001)
        XCTAssertEqual(ConfirmationSweep.softness(atProgress: 1), 0, accuracy: 0.001)
        let before = ConfirmationSweep.opacity(forCharacterAt: 9, boundary: 10, softness: softness)
        let after = ConfirmationSweep.opacity(forCharacterAt: 10, boundary: 10, softness: softness)
        XCTAssertGreaterThan(before, after)
        XCTAssertLessThan(before, 1)
        XCTAssertGreaterThan(after, ConfirmationSweep.unconfirmedOpacity)
    }
}
