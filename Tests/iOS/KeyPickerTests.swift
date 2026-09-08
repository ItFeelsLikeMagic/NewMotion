import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The phone half of the Command picker: turning a two-axis drag into the cell
/// the Mac should light, and telling a tap apart from a slide.
final class KeyPickerPressTests: XCTestCase {
    private let firstCell = KeyPickerGrid.rows[0][0]

    /// A press costs no messages until the finger actually moves, which is
    /// what keeps a stray tap on this key free.
    func testAPressThatNeverMovedSaysNothing() {
        var press = KeyPickerPress()

        XCTAssertFalse(press.isLit)
        XCTAssertNil(press.cell)
        XCTAssertNil(press.lift(committing: true))
    }

    /// Whichever way the finger went, the first notch opens the card on the
    /// grid's first cell, so no direction can cost a press its card.
    func testTheFirstNotchOpensTheCardOnTheFirstCell() {
        for step in [SlideStep.left, .right, .up, .down] {
            var press = KeyPickerPress()

            XCTAssertEqual(
                press.notch(step),
                [
                    KeyPickerPayload(phase: .begin),
                    KeyPickerPayload(phase: .highlight, cell: firstCell)
                ]
            )
            XCTAssertTrue(press.isLit)
        }
    }

    func testEachNotchAfterTheFirstMovesOneCell() {
        var press = KeyPickerPress()

        _ = press.notch(.right)
        XCTAssertEqual(
            press.notch(.right),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[0][1])]
        )
        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[1][1])]
        )
    }

    /// Overshoot is absorbed rather than banked, so a step back from an edge
    /// moves the highlight at once instead of retracing the dead travel.
    func testAStepOffTheEdgeSaysNothingAndIsNotBanked() {
        var press = KeyPickerPress()

        _ = press.notch(.right)
        XCTAssertEqual(press.notch(.left), [])
        XCTAssertEqual(press.notch(.up), [])
        XCTAssertEqual(
            press.notch(.right),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[0][1])]
        )
    }

    func testAStepBackUndoesAStepForward() {
        var press = KeyPickerPress()

        _ = press.notch(.down)
        XCTAssertEqual(
            press.notch(.down),
            [KeyPickerPayload(phase: .highlight, cell: KeyPickerGrid.rows[1][0])]
        )
        XCTAssertEqual(
            press.notch(.up),
            [KeyPickerPayload(phase: .highlight, cell: firstCell)]
        )
    }

    /// The last row is a cell short, so the column the row above allows is off
    /// the end of it.  The highlight stays where it is rather than wrapping.
    func testDroppingIntoTheShortLastRowFromItsMissingColumnIsIgnored() {
        var press = KeyPickerPress()
        XCTAssertEqual(KeyPickerGrid.rows[2].count + 1, KeyPickerGrid.rows[1].count)

        for _ in 0..<5 { _ = press.notch(.right) }
        _ = press.notch(.down)
        XCTAssertEqual(press.cell, KeyPickerGrid.rows[1][4])
        XCTAssertEqual(press.notch(.down), [])
        XCTAssertEqual(press.cell, KeyPickerGrid.rows[1][4])
    }

    /// Commit names its own cell, so a highlight lost on the way costs a stale
    /// card rather than the wrong shortcut.
    func testCommitCarriesTheLitCell() {
        var press = KeyPickerPress()

        _ = press.notch(.down)
        _ = press.notch(.down)
        XCTAssertEqual(
            press.lift(committing: true),
            KeyPickerPayload(phase: .commit, cell: KeyPickerGrid.rows[1][0])
        )
        XCTAssertFalse(press.isLit)
    }

    /// A cancelled press closes the card and names nothing, so the Mac has
    /// nothing it could fire.
    func testCancelAfterTheCardOpenedNamesNoCell() {
        var press = KeyPickerPress()

        _ = press.notch(.right)
        XCTAssertEqual(press.lift(committing: false), KeyPickerPayload(phase: .cancel))
        XCTAssertNil(press.cell)
    }

    /// The grid is drawn from the shared table, so every cell the phone can
    /// light has a name to show while sliding.
    func testEveryCellHasADisplayName() {
        for cell in KeyPickerGrid.rows.flatMap({ $0 }) {
            XCTAssertNotNil(KeyPickerGrid.displayName(for: cell))
        }
    }
}
