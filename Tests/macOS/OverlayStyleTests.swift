import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// The tuned look: what survives a quit, what happens when it cannot be read
/// back, and the panel that has to be sized from it.
@MainActor
final class OverlayStyleTests: XCTestCase {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "newmotion.style.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// Every field has to come back, or a tuned card resets itself on the next
    /// launch and the tuning was for nothing.
    func testAStyleRoundTripsThroughJSON() throws {
        var style = MacOverlayStyle.standard
        style.glass = .frosted
        style.tintsLitKey = false
        style.glassOpacity = 0.35
        style.backing = 0.4
        style.tileSide = 110
        style.tileCorner = 6
        style.tileSpacing = 22
        style.capFontSize = 44
        style.showsNames = false
        style.nameFontSize = 14
        style.boldCaps = true
        style.textShadow = true
        style.stagger = 0.5
        style.fadeDuration = 0.3
        style.captionOnDeleteCard = false

        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(MacOverlayStyle.self, from: data), style)

        let suite = defaults()
        let store = MacOverlayStyleStore(defaults: suite)
        store.style = style
        XCTAssertEqual(MacOverlayStyleStore(defaults: suite).style, style)
    }

    /// A style written by a build with different fields is unreadable here.
    /// Falling back beats refusing to draw a card at all.
    func testUnreadableStoredStyleFallsBackToStandard() {
        let suite = defaults()
        suite.set(Data("not a style".utf8), forKey: "overlayStyle")
        XCTAssertEqual(MacOverlayStyleStore(defaults: suite).style, .standard)
    }

    /// The panel is sized from the same numbers that draw the grid, so a
    /// bigger key has to make a bigger pane or the card is clipped.
    func testPanelSizeGrowsWithTheTile() {
        var bigger = MacOverlayStyle.standard
        bigger.tileSide = MacOverlayStyle.tileSideRange.upperBound
        XCTAssertGreaterThan(bigger.panelSize.width, MacOverlayStyle.standard.panelSize.width)
        XCTAssertGreaterThan(bigger.panelSize.height, MacOverlayStyle.standard.panelSize.height)
    }

    /// The stagger reproduces the offsets the grid was drawn with before it
    /// was tunable: no offset, a quarter tile, three quarters.
    func testTheStandardStaggerIsTheOffsetTheGridHad() {
        let style = MacOverlayStyle.standard
        XCTAssertEqual(style.rowOffset(0), 0)
        XCTAssertEqual(style.rowOffset(1), 21, accuracy: 0.001)
        XCTAssertEqual(style.rowOffset(2), 63, accuracy: 0.001)
        XCTAssertEqual(style.rowOffset(3), 0)
    }
}
