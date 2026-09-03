import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

/// The phone half of the held delete key: turning sideways travel into whole
/// notches, and telling a tap apart from a slide.
final class DeleteScrubTests: XCTestCase {
    private let width = SlideNotchCounter.baseStepWidth

    func testSlidingLeftTakesOneNotchPerStepWidth() {
        var tracker = DeleteScrubTracker()

        XCTAssertEqual(tracker.advance(translationX: -width * 0.9), [])
        XCTAssertEqual(tracker.advance(translationX: -width), [.delete])
        XCTAssertEqual(tracker.advance(translationX: -width * 3), [.delete, .delete])
        XCTAssertEqual(tracker.steps, 3)
    }

    func testSlidingBackRestoresTheSameCount() {
        var tracker = DeleteScrubTracker()

        XCTAssertEqual(tracker.advance(translationX: -width * 4), [.delete, .delete, .delete, .delete])
        XCTAssertEqual(tracker.advance(translationX: -width * 2), [.restore, .restore])
        XCTAssertEqual(tracker.steps, 2)
    }

    /// Travel is measured from where the finger landed, so a wobble on the way
    /// out cannot leave the count somewhere the finger is not.
    func testCountFollowsTheFingerRatherThanTheWayItGotThere() {
        var tracker = DeleteScrubTracker()

        _ = tracker.advance(translationX: -width * 5)
        _ = tracker.advance(translationX: -width * 1)
        XCTAssertEqual(tracker.advance(translationX: -width * 5), Array(repeating: .delete, count: 4))
        XCTAssertEqual(tracker.steps, 5)
    }

    /// There is nothing to restore past what this press deleted, so sliding
    /// right from a standing start does nothing at all.
    func testSlidingRightPastTheStartIsIgnored() {
        var tracker = DeleteScrubTracker()

        XCTAssertEqual(tracker.advance(translationX: width * 6), [])
        XCTAssertEqual(tracker.steps, 0)
        XCTAssertFalse(tracker.hasStepped)
    }

    /// The flag is what makes a press send an ordinary delete on release.  A
    /// slide out and back has still erased something, so it must not.
    func testASlideThatEndsWhereItStartedStillCountsAsASlide() {
        var tracker = DeleteScrubTracker()

        _ = tracker.advance(translationX: -width * 2)
        _ = tracker.advance(translationX: 0)
        XCTAssertEqual(tracker.steps, 0)
        XCTAssertTrue(tracker.hasStepped)
    }

    /// The bug this ratchet exists for.  Sliding well past the end of the text
    /// spends notches on nothing.  Coming back must start restoring at once,
    /// not after retracing every one of them, which is further than the glass
    /// is wide.
    func testComingBackFromAnOverlongSlideRestoresStraightAway() {
        var tracker = DeleteScrubTracker()

        XCTAssertEqual(tracker.advance(translationX: -width * 16).count, 16)
        XCTAssertEqual(tracker.advance(translationX: -width * 14), [.restore, .restore])
    }

    /// The count stops at zero, but the finger is still moving, so the next
    /// notch leftwards is one notch of travel away rather than a slide back
    /// across everything the count would not take.
    func testTravelPastZeroStillCountsAsTravel() {
        var tracker = DeleteScrubTracker()

        XCTAssertEqual(tracker.advance(translationX: width * 5), [])
        XCTAssertEqual(tracker.advance(translationX: width * 4), [.delete])
        XCTAssertEqual(tracker.steps, 1)
    }

    func testSensitivityShortensTheNotch() {
        var tracker = DeleteScrubTracker(sensitivity: 2)

        XCTAssertEqual(tracker.advance(translationX: -width), [.delete, .delete])
    }

    func testEveryStepHasAWirePhase() {
        XCTAssertEqual(DeleteScrubStep.delete.phase, .delete)
        XCTAssertEqual(DeleteScrubStep.restore.phase, .restore)
    }
}

/// The two-axis drag behind the selection key and the arrow pad.  It runs on
/// the same notch counter as the delete keys, so these tests only cover what
/// differs: two axes, and no floor at zero.
final class SlideStepTests: XCTestCase {
    private let width = SlideNotchCounter.baseStepWidth

    func testSidewaysTravelTakesCharactersAndVerticalTakesLines() {
        var tracker = SlideStepTracker()

        XCTAssertEqual(tracker.advance(translationX: -width * 0.9, translationY: 0), [])
        XCTAssertEqual(tracker.advance(translationX: -width * 3, translationY: 0), [.left, .left, .left])
        XCTAssertEqual(tracker.advance(translationX: -width * 3, translationY: -width * 2), [.up, .up])
        XCTAssertEqual(tracker.advance(translationX: -width * 3, translationY: width * 2), [.down, .down, .down, .down])
    }

    /// A diagonal drag extends the selection both ways at once, which is what
    /// holding Shift and pressing two arrows does.
    func testADiagonalDragTakesBothAxes() {
        var tracker = SlideStepTracker()

        XCTAssertEqual(
            tracker.advance(translationX: width * 2, translationY: -width),
            [.right, .right, .up]
        )
    }

    /// Nothing is clamped: dragging back the other way shrinks the selection
    /// rather than being ignored, because the arrow undoes itself.
    func testDraggingBackShrinksTheSelection() {
        var tracker = SlideStepTracker()

        XCTAssertEqual(tracker.advance(translationX: -width * 2, translationY: 0), [.left, .left])
        XCTAssertEqual(tracker.advance(translationX: 0, translationY: 0), [.right, .right])
        XCTAssertEqual(tracker.advance(translationX: width * 2, translationY: 0), [.right, .right])
    }

    func testEveryStepHasASelectionHotkey() {
        XCTAssertEqual(SlideStep.left.selectionHotkey, .selectLeft)
        XCTAssertEqual(SlideStep.right.selectionHotkey, .selectRight)
        XCTAssertEqual(SlideStep.up.selectionHotkey, .selectUp)
        XCTAssertEqual(SlideStep.down.selectionHotkey, .selectDown)
    }

    /// The arrow pad is the same drag with the Shift left off.
    func testEveryStepHasAPlainArrowHotkey() {
        XCTAssertEqual(SlideStep.left.arrowHotkey, .arrowLeft)
        XCTAssertEqual(SlideStep.right.arrowHotkey, .arrowRight)
        XCTAssertEqual(SlideStep.up.arrowHotkey, .arrowUp)
        XCTAssertEqual(SlideStep.down.arrowHotkey, .arrowDown)
    }
}
