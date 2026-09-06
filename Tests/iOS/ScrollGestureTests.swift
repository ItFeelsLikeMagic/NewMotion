import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The two experimental ways to scroll with one finger: land in a side strip,
/// or rest long enough to take the clutch.
final class ScrollGestureTests: XCTestCase {
    private func engine(edge: Double = 44, hold: TimeInterval = 0.35, width: Double = 400) -> TrackpadGestureEngine {
        var engine = TrackpadGestureEngine(
            configuration: TrackpadConfiguration(edgeScrollWidth: edge, holdScrollDelay: hold)
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

    func testRestingLongEnoughTurnsTravelIntoScroll() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 100), phase: .began, timestamp: 0)
        ])
        let outputs = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .moved, timestamp: 0.4)
        ])
        XCTAssertEqual(scrollTravel(outputs), 40)
        XCTAssertTrue(engine.isScrollClutchEngaged)
    }

    func testMovingBeforeTheDelayKeepsMovingTheCursor() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 100), phase: .began, timestamp: 0)
        ])
        let early = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .moved, timestamp: 0.1)
        ])
        XCTAssertEqual(pointerTravel(early), 40)
        // Still a cursor drag once the finger has been down past the delay:
        // the clutch is claimed by the rest, not by elapsed time alone.
        let later = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 180), phase: .moved, timestamp: 0.5)
        ])
        XCTAssertEqual(pointerTravel(later), 40)
        XCTAssertFalse(engine.isScrollClutchEngaged)
    }

    func testClutchClearsWhenTheFingerLifts() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 100), phase: .began, timestamp: 0)
        ])
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .moved, timestamp: 0.4)
        ])
        XCTAssertTrue(engine.isScrollClutchEngaged)
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .ended, timestamp: 0.5)
        ])
        XCTAssertFalse(engine.isScrollClutchEngaged)
    }

    /// A hold long enough to clutch is already past the tap window, so lifting
    /// out of a scroll must not also click.
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

    func testTurningBothExperimentsOffReleasesAHeldClutch() {
        var engine = engine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 100), phase: .began, timestamp: 0)
        ])
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 200, y: 140), phase: .moved, timestamp: 0.4)
        ])
        XCTAssertTrue(engine.isScrollClutchEngaged)
        engine.setScrollGestures(edgeScrollWidth: 0, holdScrollDelay: 0)
        XCTAssertFalse(engine.isScrollClutchEngaged)
    }
}
