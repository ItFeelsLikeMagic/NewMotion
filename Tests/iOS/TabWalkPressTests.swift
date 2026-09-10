import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// One whole press of the walk key: which row it is walking, and what the
/// phone owes the Mac between the finger landing and the finger lifting.
final class TabWalkPressTests: XCTestCase {
    private let step = TabWalkPress.stepWidth
    private let travel = SlideDial.travel

    func testAPressOpensTheAppSwitcher() {
        var press = TabWalkPress()

        XCTAssertEqual(press.begin(), [TabWalkPayload(phase: .begin, row: .apps)])
        XCTAssertTrue(press.hasBegun)
    }

    /// Begin already takes the first step, so a tap is the ordinary one-step
    /// flip and the lift only has to let the modifier go.
    func testATapCommitsWithoutStepping() {
        var press = TabWalkPress()
        _ = press.begin()

        XCTAssertEqual(press.lift(committing: true), [TabWalkPayload(phase: .commit, row: .apps)])
        XCTAssertFalse(press.hasBegun)
    }

    func testSlidingWalksTheRowBothWays() {
        var press = TabWalkPress()
        _ = press.begin()

        XCTAssertEqual(press.move(translationX: step * 0.9, translationY: 0), [])
        XCTAssertEqual(
            press.move(translationX: step * 2, translationY: 0),
            [TabWalkPayload(phase: .next, row: .apps), TabWalkPayload(phase: .next, row: .apps)]
        )
        XCTAssertEqual(
            press.move(translationX: step, translationY: 0),
            [TabWalkPayload(phase: .previous, row: .apps)]
        )
    }

    /// Up is tabs and down is windows, and the message names the row being
    /// left so the Mac can let go of whatever that row held.
    func testSlidingUpTakesTabsAndSlidingDownTakesWindows() {
        var press = TabWalkPress()
        _ = press.begin()

        XCTAssertEqual(
            press.move(translationX: 0, translationY: -travel),
            [TabWalkPayload(phase: .swap, row: .tabs, leaving: .apps)]
        )
        XCTAssertEqual(press.row, .tabs)

        XCTAssertEqual(
            press.move(translationX: 0, translationY: 0),
            [TabWalkPayload(phase: .swap, row: .apps, leaving: .tabs)]
        )
        XCTAssertEqual(
            press.move(translationX: 0, translationY: travel),
            [TabWalkPayload(phase: .swap, row: .windows, leaving: .apps)]
        )
        XCTAssertEqual(press.row, .windows)
    }

    /// The dial stops at both ends, so a slide that runs off the phone cannot
    /// turn up a fourth row, and the way back is one turn from where it stuck.
    func testTheDialStopsAtBothEnds() {
        var press = TabWalkPress()
        _ = press.begin()

        XCTAssertEqual(press.move(translationX: 0, translationY: -travel * 3).count, 1)
        XCTAssertEqual(press.row, .tabs)
        XCTAssertEqual(press.move(translationX: 0, translationY: -travel * 4), [])
        XCTAssertEqual(press.row, .tabs)

        XCTAssertEqual(press.move(translationX: 0, translationY: -travel * 3).count, 1)
        XCTAssertEqual(press.row, .apps)
    }

    /// The travel spent getting to the swap is not charged to the row that
    /// follows: the new walk starts where the finger stands.
    func testStepsAfterASwapAreCountedFromTheSwap() {
        var press = TabWalkPress()
        _ = press.begin()
        _ = press.move(translationX: step * 3, translationY: 0)

        XCTAssertEqual(
            press.move(translationX: step * 3, translationY: -travel),
            [TabWalkPayload(phase: .swap, row: .tabs, leaving: .apps)]
        )
        XCTAssertEqual(
            press.move(translationX: step * 4, translationY: -travel),
            [TabWalkPayload(phase: .next, row: .tabs)]
        )
    }

    func testTheLiftReleasesWhicheverRowIsOpen() {
        var press = TabWalkPress()
        _ = press.begin()
        _ = press.move(translationX: 0, translationY: -travel)

        XCTAssertEqual(press.lift(committing: false), [TabWalkPayload(phase: .cancel, row: .tabs)])
    }

    /// A row a thumb chose lasts only for the press that chose it, so the key
    /// is never the tab switcher because of how the last press ended.
    func testEveryPressStartsBackOnApps() {
        var press = TabWalkPress()
        _ = press.begin()
        _ = press.move(translationX: 0, translationY: -travel)
        _ = press.lift(committing: true)

        XCTAssertEqual(press.row, .apps)
        XCTAssertEqual(press.begin(), [TabWalkPayload(phase: .begin, row: .apps)])
    }

    /// Travel with no press behind it is travel on the trackpad, not on this
    /// key, and a second lift has nothing left to release.
    func testTravelAndLiftsOutsideAPressSayNothing() {
        var press = TabWalkPress()

        XCTAssertEqual(press.move(translationX: step * 4, translationY: -travel), [])
        XCTAssertEqual(press.lift(committing: true), [])
    }

    /// A walk that holds nothing open leaves nothing for the watchdog to
    /// release, and one that does must be counted so a lost lift is repaired.
    func testOnlyTheRowsThatHoldSomethingAreCounted() {
        XCTAssertEqual(TabWalkRow.apps.heldModifier, .command)
        XCTAssertEqual(TabWalkRow.tabs.heldModifier, .control)
        XCTAssertNil(TabWalkRow.windows.heldModifier)
    }
}
