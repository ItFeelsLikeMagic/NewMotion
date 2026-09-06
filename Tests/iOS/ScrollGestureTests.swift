import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// Scrolling with one finger: land in a side strip and travel.
final class ScrollGestureTests: XCTestCase {
    private func engine(edge: Double = 44, width: Double = 400) -> TrackpadGestureEngine {
        var engine = TrackpadGestureEngine(
            configuration: TrackpadConfiguration(edgeScrollWidth: edge)
        )
        engine.setSurfaceWidth(width)
        return engine
    }

    private func scrollTravel(_ outputs: [RemoteInputEvent]) -> Double {
        outputs.reduce(into: 0.0) { total, output in
            if case let .scroll(delta) = output { total += delta.y }
        }
    }

    private func pointerTravel(_ outputs: [RemoteInputEvent]) -> Double {
        outputs.reduce(into: 0.0) { total, output in
            if case let .pointer(delta) = output { total += delta.y }
        }
    }

    func testLeftStripScrollsInsteadOfMovingTheCursor() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 140), phase: .moved, timestamp: 0.02)
        ])
        XCTAssertEqual(scrollTravel(outputs), 40)
        XCTAssertEqual(pointerTravel(outputs), 0)
    }

    func testRightStripScrolls() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 390, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 390, y: 60), phase: .moved, timestamp: 0.02)
        ])
        XCTAssertEqual(scrollTravel(outputs), -40)
    }

    func testMiddleOfTheSurfaceStillMovesTheCursor() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .moved, timestamp: 0.02)
        ])
        XCTAssertEqual(pointerTravel(outputs), 40)
        XCTAssertEqual(scrollTravel(outputs), 0)
    }

    func testStripsAreOffWhenTheWidthIsZero() {
        var engine = engine(edge: 0)
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 140), phase: .moved, timestamp: 0.02)
        ])
        XCTAssertEqual(pointerTravel(outputs), 40)
    }

    /// Strips wider than a third of the glass would leave no room to point.
    func testStripsAreOffOnASurfaceTooNarrowToHoldThem() {
        var engine = engine(edge: 44, width: 100)
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 5, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 5, y: 140), phase: .moved, timestamp: 0.02)
        ])
        XCTAssertEqual(pointerTravel(outputs), 40)
    }

    /// Where the finger lands is the whole decision.  Resting in the middle
    /// before moving is a slow, careful cursor drag, never a scroll.
    func testRestingInTheMiddleStillMovesTheCursor() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .moved, timestamp: 0.4)
        ])
        XCTAssertEqual(pointerTravel(outputs), 40)
        XCTAssertFalse(engine.isOneFingerScrolling)
    }

    func testScrollingClearsWhenTheFingerLifts() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 100), phase: .began, timestamp: 0)
        ])
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 140), phase: .moved, timestamp: 0.4)
        ])
        XCTAssertTrue(engine.isOneFingerScrolling)
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 140), phase: .ended, timestamp: 0.5)
        ])
        XCTAssertFalse(engine.isOneFingerScrolling)
    }

    /// A strip scroll travels well past the tap window, so lifting out of one
    /// must not also click.
    func testScrollingWithOneFingerDoesNotClickOnLift() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 100), phase: .began, timestamp: 0)
        ])
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 160), phase: .moved, timestamp: 0.4)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 160), phase: .ended, timestamp: 0.5)
        ])
        XCTAssertFalse(outputs.contains(.leftClick))
    }

    /// Tapping in a strip is still a click; only travel there scrolls.
    func testTapInsideAStripStillClicks() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 100), phase: .ended, timestamp: 0.1)
        ])
        XCTAssertTrue(outputs.contains(.leftClick))
    }
}
