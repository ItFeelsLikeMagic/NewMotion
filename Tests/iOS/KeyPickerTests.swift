import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The phone half of the Command picker: turning a two-axis drag into the cell
/// the Mac should light, and telling a press left on Cancel from one that was
/// aimed somewhere.
final class KeyPickerPressTests: XCTestCase {
    /// The cell one notch down from where a press starts: Cancel has a row to
    /// itself, so down is the only way off it.
    private let secondCell = KeyPickerGrid.rows[1][0]

    /// Touch-down opens the card on Cancel, so it is already on the Mac screen
    /// before the finger has moved and lifting there fires nothing.
    func testTheKeyGoingDownOpensTheCardOnCancel() {
        var press = KeyPickerPress()

        XCTAssertEqual(press.begin(), KeyPickerPayload(phase: .begin))
        XCTAssertTrue(press.hasBegun)
        XCTAssertEqual(press.cell, .cancel)
        XCTAssertNil(press.cell.hotkey)
        XCTAssertNil(press.begin())
    }

    /// A press with no touch behind it has no card to close.
    func testALiftWithNoPressSaysNothing() {
        var press = KeyPickerPress()

        XCTAssertNil(press.lift(committing: true))
        XCTAssertNil(press.keepalive)
        XCTAssertEqual(press.notch(.right), [])
    }

    /// Every notch moves one cell, the first one included: the press already
    /// has an aim, so nothing has to be spent lighting one.
    func testTheFirstNotchDownLeavesCancelForTheKeyBelowIt() {
        var press = KeyPickerPress()
        _ = press.begin()

        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: secondCell.hotkey)]
        )
        XCTAssertEqual(press.cell, secondCell)
    }

    func testEachNotchMovesOneCell() {
        var press = KeyPickerPress()
        _ = press.begin()

        _ = press.notch(.down)
        _ = press.notch(.right)
        XCTAssertEqual(
            press.notch(.right),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[1][2].hotkey)]
        )
        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[2][2].hotkey)]
        )
    }

    /// Overshoot is absorbed rather than banked, so a step back from an edge
    /// moves the highlight at once instead of retracing the dead travel.
    func testAStepOffTheEdgeFromCancelSaysNothingAndIsNotBanked() {
        var press = KeyPickerPress()
        _ = press.begin()

        XCTAssertEqual(press.notch(.left), [])
        XCTAssertEqual(press.notch(.up), [])
        XCTAssertEqual(press.notch(.right), [])
        XCTAssertEqual(press.cell, .cancel)
        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: secondCell.hotkey)]
        )
    }

    /// Sliding up is the way out, so the top of every column is Cancel, not
    /// an edge that swallows the step.
    func testAStepUpFromAnyTopRowKeyLandsOnCancel() {
        var press = KeyPickerPress()
        _ = press.begin()
        _ = press.notch(.down)
        for _ in 0..<4 { _ = press.notch(.right) }
        XCTAssertEqual(press.cell, KeyPickerGrid.rows[1][4])

        XCTAssertEqual(press.notch(.up), [KeyPickerPayload(phase: .highlight, cell: nil)])
        XCTAssertEqual(press.cell, .cancel)
    }

    func testAStepBackUndoesAStepForward() {
        var press = KeyPickerPress()
        _ = press.begin()

        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[1][0].hotkey)]
        )
        XCTAssertEqual(
            press.notch(.up),
            [KeyPickerPayload(phase: .highlight, cell: nil)]
        )
        XCTAssertEqual(press.cell, .cancel)
    }

    /// The home row is shorter than the rows either side of it, so a column
    /// it lacks passes straight over it: down from the top row's last key
    /// lands on the bottom row, and back up returns the same way.
    func testAShortRowIsCrossedByAColumnItDoesNotHave() {
        var press = KeyPickerPress()
        _ = press.begin()
        XCTAssertLessThan(KeyPickerGrid.rows[2].count, KeyPickerGrid.rows[1].count)
        XCTAssertEqual(KeyPickerGrid.rows[1].count, 5)

        _ = press.notch(.down)
        for _ in 0..<5 { _ = press.notch(.right) }
        XCTAssertEqual(press.cell, KeyPickerGrid.rows[1][4])
        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[3][4].hotkey)]
        )
        XCTAssertEqual(
            press.notch(.up),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[1][4].hotkey)]
        )
    }

    /// A column no row above has goes all the way up to Cancel.
    func testAColumnOnlyTheBottomRowHasGoesStraightUpToCancel() {
        var press = KeyPickerPress()
        _ = press.begin()
        _ = press.notch(.down)
        _ = press.notch(.down)
        _ = press.notch(.down)
        for _ in 0..<5 { _ = press.notch(.right) }
        XCTAssertEqual(press.cell, KeyPickerGrid.rows[3][5])

        XCTAssertEqual(press.notch(.up), [KeyPickerPayload(phase: .highlight, cell: nil)])
        XCTAssertEqual(press.cell, .cancel)
    }

    /// A press left on Cancel still closes the card it opened, and names no
    /// cell, so the Mac has nothing it could fire.
    func testLiftingOnCancelCommitsWithNoCell() {
        var press = KeyPickerPress()
        _ = press.begin()

        XCTAssertEqual(press.lift(committing: true), KeyPickerPayload(phase: .commit))
        XCTAssertFalse(press.hasBegun)
    }

    /// Commit names its own cell, so a highlight lost on the way costs a stale
    /// card rather than the wrong shortcut.
    func testCommitCarriesTheLitCell() {
        var press = KeyPickerPress()
        _ = press.begin()

        _ = press.notch(.down)
        XCTAssertEqual(
            press.lift(committing: true),
            KeyPickerPayload(phase: .commit, cell: KeyPickerGrid.rows[1][0].hotkey)
        )
        XCTAssertEqual(press.cell, .cancel)
    }

    /// A cancelled press closes the card and names nothing, whether or not the
    /// finger ever moved.
    func testCancelAfterTheCardOpenedNamesNoCell() {
        var press = KeyPickerPress()
        _ = press.begin()
        XCTAssertEqual(press.lift(committing: false), KeyPickerPayload(phase: .cancel))

        var slid = KeyPickerPress()
        _ = slid.begin()
        _ = slid.notch(.down)
        XCTAssertEqual(slid.lift(committing: false), KeyPickerPayload(phase: .cancel))
    }

    /// The Mac closes a card that has gone quiet, so a thumb resting on a cell
    /// says that cell again rather than nothing.  Cancel says it the way the
    /// wire does, by naming no cell at all.
    func testTheKeepaliveRepeatsTheLitCell() {
        var press = KeyPickerPress()
        _ = press.begin()
        XCTAssertEqual(press.keepalive, KeyPickerPayload(phase: .highlight, cell: nil))

        _ = press.notch(.down)
        XCTAssertEqual(
            press.keepalive,
            KeyPickerPayload(phase: .highlight, cell: secondCell.hotkey)
        )

        _ = press.lift(committing: true)
        XCTAssertNil(press.keepalive)
    }
}
