import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

/// The gesture engine no longer rate limits; `CursorMixer` is the
/// only pacer on the way to the link.
final class TrackpadPacingTests: XCTestCase {
    func testEveryTouchBatchEmitsRegardlessOfSpacing() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)
        ])
        // 120 Hz touches: the old 100 Hz gate swallowed every other one.
        var emitted = 0
        for step in 1...6 {
            let outputs = engine.handle([
                TrackpadTouch(
                    id: 1,
                    location: TrackpadPoint(x: Double(step) * 4, y: 0),
                    phase: .moved,
                    timestamp: Double(step) / 120
                )
            ])
            emitted += outputs.count
        }
        XCTAssertEqual(emitted, 6)
    }

    func testSubPointTravelStillAccumulatesIntoWholePoints() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)
        ])
        var total = 0.0
        for step in 1...10 {
            for case let .pointer(delta) in engine.handle([
                TrackpadTouch(
                    id: 1,
                    location: TrackpadPoint(x: Double(step) * 0.3, y: 0),
                    phase: .moved,
                    timestamp: Double(step) / 120
                )
            ]) {
                total += delta.x
            }
        }
        XCTAssertEqual(total, 3)
    }

    func testCursorTravelKeepsTheFractionAndTheOverflow() {
        var travel = CursorTravel()
        // A tenth of a point on its own moves nothing.
        travel.add(x: 0.1, y: 0)
        XCTAssertEqual(travel.wholePoints.x, 0)

        // Ten of them must add up to a whole point, not to nothing.
        var sent = 0
        for _ in 0..<9 {
            travel.add(x: 0.1, y: 0)
            let step = travel.wholePoints
            travel.take(x: step.x, y: step.y)
            sent += Int(step.x)
        }
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(travel.wholePoints.x, 0)

        // Travel past what one frame carries waits rather than vanishing.
        travel.clear()
        travel.add(x: Double(Int16.max) + 40, y: 0)
        let capped = travel.wholePoints
        XCTAssertEqual(capped.x, Int16.max)
        travel.take(x: capped.x, y: capped.y)
        XCTAssertEqual(travel.wholePoints.x, 40)
    }

    func testMotionGainIsFinerWhenSlowAndFasterWhenSweeping() {
        // Gain is output points per radian of turn. The curve must give a slow
        // aim less of it than a fast sweep, and both must still move.
        func gain(degreesPerSecond: Double) -> Double {
            var filter = MotionPointerFilter()
            filter.setClutch(active: true)
            let perSample = degreesPerSecond * .pi / 180 / 100
            var timestamp = 0.0
            var output = 0.0
            var turned = 0.0
            for step in 0...40 {
                timestamp = Double(step) / 100
                let angle = perSample * Double(step)
                let delta = filter.process(MotionSample(
                    timestamp: timestamp,
                    attitude: MotionQuaternion(w: cos(angle / 2), x: 0, y: 0, z: sin(angle / 2))
                ))
                // The first accepted sample only sets the reference.
                if step > 1 { turned += perSample }
                output += abs(delta?.x ?? 0)
            }
            return output / turned
        }

        let slow = gain(degreesPerSecond: 5)
        let aiming = gain(degreesPerSecond: 30)
        let sweep = gain(degreesPerSecond: 300)
        XCTAssertGreaterThan(slow, 0)
        XCTAssertLessThan(slow, aiming)
        XCTAssertGreaterThan(sweep, aiming)
    }

    func testCoalescerSumsPointerTravelAndKeepsDiscreteEventsBehindIt() {
        let coalescer = CursorMixer()
        var seen: [RemoteInputEvent] = []
        var deferred: [() -> Void] = []
        coalescer.onEvent = { seen.append($0) }
        coalescer.travelCoalescer.now = { 0 }
        coalescer.travelCoalescer.execute = { _, work in deferred.append(work) }

        coalescer.handle([
            .pointer(CursorDelta(x: 3, y: 1)),
            .pointer(CursorDelta(x: 4, y: 1)),
            .leftClick
        ])
        XCTAssertEqual(seen, [
            .pointer(CursorDelta(x: 7, y: 2)),
            .leftClick
        ])
        XCTAssertEqual(deferred.count, 1)
    }
}
