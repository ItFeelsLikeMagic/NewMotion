import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// The settled look: the panel that has to be sized from it, and the row
/// stagger the grid is laid out on.
@MainActor
final class OverlayStyleTests: XCTestCase {
    /// The panel is sized from the same numbers that draw the grid, and the
    /// card is never measured, so a pane too small for the widest row clips
    /// the card for good.
    func testThePanelHoldsTheWidestRowAndEveryRow() {
        let rows = KeyPickerGrid.rows
        let widest: CGFloat = (0..<rows.count).map { index in
            let across: CGFloat = span(rows[index].count)
            return MacOverlayStyle.rowOffset(index) + across
        }.max() ?? 0
        let tall: CGFloat = span(rows.count)
        let room: CGFloat = 2 * MacOverlayStyle.spareRoom

        XCTAssertEqual(MacOverlayStyle.panelSize.width, max(widest, MacOverlayStyle.maximumWidth) + room)
        XCTAssertEqual(MacOverlayStyle.panelSize.height, tall + room)
    }

    /// Tiles end to end with a gap between each pair, which is what the grid
    /// itself is laid out on.
    private func span(_ count: Int) -> CGFloat {
        let tiles: CGFloat = CGFloat(count) * MacOverlayStyle.tileSide
        let gaps: CGFloat = CGFloat(count - 1) * MacOverlayStyle.tileSpacing
        return tiles + gaps
    }

    /// The stagger is a quarter tile for the home row and three quarters for
    /// the bottom one, with nothing above them.
    func testTheStaggerIsAQuarterAndThreeQuartersOfATile() {
        XCTAssertEqual(MacOverlayStyle.rowOffset(0), 0)
        XCTAssertEqual(MacOverlayStyle.rowOffset(1), 0)
        XCTAssertEqual(MacOverlayStyle.rowOffset(2), 25, accuracy: 0.001)
        XCTAssertEqual(MacOverlayStyle.rowOffset(3), 75, accuracy: 0.001)
        XCTAssertEqual(MacOverlayStyle.rowOffset(4), 0)
    }
}
