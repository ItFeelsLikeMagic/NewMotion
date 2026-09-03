import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

/// The gesture engine no longer rate limits; `TrackpadOutputCoalescer` is the
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

    func testCoalescerSumsPointerTravelAndKeepsDiscreteEventsBehindIt() {
        let coalescer = TrackpadOutputCoalescer()
        var seen: [TrackpadOutput] = []
        var deferred: [() -> Void] = []
        coalescer.onOutput = { seen.append($0) }
        coalescer.pointerCoalescer.now = { 0 }
        coalescer.pointerCoalescer.execute = { _, work in deferred.append(work) }

        coalescer.handle([
            .pointer(TrackpadPointerDelta(x: 3, y: 1)),
            .pointer(TrackpadPointerDelta(x: 4, y: 1)),
            .leftClick
        ])
        XCTAssertEqual(seen, [
            .pointer(TrackpadPointerDelta(x: 7, y: 2)),
            .leftClick
        ])
        XCTAssertEqual(deferred.count, 1)
    }
}
