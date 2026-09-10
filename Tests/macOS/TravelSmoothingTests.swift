import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

final class TravelSmoothingTests: XCTestCase {
    private func scrolled(_ events: [InjectedInputEvent]) -> (x: Double, y: Double) {
        events.reduce(into: (x: 0.0, y: 0.0)) { total, event in
            guard case let .scroll(delta) = event else { return }
            total.x += delta.x
            total.y += delta.y
        }
    }

    private func travel(_ events: [InjectedInputEvent]) -> (x: Double, y: Double) {
        events.reduce(into: (x: 0.0, y: 0.0)) { total, event in
            guard case let .pointer(delta) = event else { return }
            total.x += delta.x
            total.y += delta.y
        }
    }

    func testOnePacketArrivesAsSeveralSmallerMovesAndLosesNothing() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink, minimumSmoothed: 0)

        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 40, y: 20)))
        // Nothing is posted on arrival; the glide owns it now.
        XCTAssertTrue(sink.events.isEmpty)

        let deadline = Date().addingTimeInterval(1)
        while travel(sink.events).x < 40, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        // Every point arrives, and in more than one step.
        XCTAssertEqual(travel(sink.events).x, 40)
        XCTAssertEqual(travel(sink.events).y, 20)
        XCTAssertGreaterThan(sink.events.count, 1)
    }

    func testAClickFlushesTheGlideSoItCannotLandBehindTheCursor() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink, minimumSmoothed: 0)

        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 30, y: 0)))
        try? smoothing.send(.mouseButton(button: .left, isDown: true, clickCount: 1))

        // The travel is posted whole, before the button.
        XCTAssertEqual(sink.events.first, .pointer(delta: MacPointerDelta(x: 30, y: 0)))
        XCTAssertEqual(sink.events.last, .mouseButton(button: .left, isDown: true, clickCount: 1))
        XCTAssertEqual(travel(sink.events).x, 30)
    }

    func testScrollGlidesAndKeepsItsWholeDistance() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink)

        try? smoothing.send(.scroll(delta: MacScrollDelta(x: 0, y: 24)))
        XCTAssertTrue(sink.events.isEmpty)

        let deadline = Date().addingTimeInterval(1)
        while scrolled(sink.events).y < 24, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(scrolled(sink.events).y, 24)
        XCTAssertGreaterThan(sink.events.count, 1)
    }

    func testCursorAndScrollGlideWithoutBlockingEachOther() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink, minimumSmoothed: 0)

        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 16, y: 0)))
        try? smoothing.send(.scroll(delta: MacScrollDelta(x: 0, y: 16)))

        let deadline = Date().addingTimeInterval(1)
        while travel(sink.events).x < 16 || scrolled(sink.events).y < 16, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(travel(sink.events).x, 16)
        XCTAssertEqual(scrolled(sink.events).y, 16)
    }

    func testASmallMoveSkipsTheGlideEntirely() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink, minimumSmoothed: 3)

        // Slow aiming: posted whole, immediately, no glide lag.
        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 2, y: 0)))
        XCTAssertEqual(sink.events, [.pointer(delta: MacPointerDelta(x: 2, y: 0))])
    }

    func testASmallMoveCannotOvertakeTravelStillGliding() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink, minimumSmoothed: 3)

        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 40, y: 0)))
        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 2, y: 0)))

        // The glide is drained first, then the small move, and nothing is lost.
        XCTAssertEqual(sink.events.first, .pointer(delta: MacPointerDelta(x: 40, y: 0)))
        XCTAssertEqual(sink.events.last, .pointer(delta: MacPointerDelta(x: 2, y: 0)))
        XCTAssertEqual(travel(sink.events).x, 42)
    }

    func testAThresholdOfZeroSmoothsEverything() {
        let sink = MockInputEventSink()
        let smoothing = SmoothedTravelSink(wrapping: sink, minimumSmoothed: 0)

        try? smoothing.send(.pointer(delta: MacPointerDelta(x: 3, y: 0)))
        XCTAssertTrue(sink.events.isEmpty)
    }
}
