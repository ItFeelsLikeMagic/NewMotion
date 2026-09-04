import XCTest
@testable import PhoneRemoteShared

final class ObservabilityTests: XCTestCase {
    func testPercentilesAndWorstUseNearestRank() {
        let tracker = LatencyTracker(name: "stage")
        for value in 1...10 { tracker.record(microseconds: UInt32(value * 1_000)) }

        let summary = try! XCTUnwrap(tracker.summary())
        XCTAssertEqual(summary.name, "stage")
        XCTAssertEqual(summary.samples, 10)
        XCTAssertEqual(summary.attempts, 10)
        XCTAssertEqual(summary.refusals, 0)
        XCTAssertEqual(summary.medianMs, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.p95Ms, 10, accuracy: 0.0001)
        XCTAssertEqual(summary.worstMs, 10, accuracy: 0.0001)
    }

    /// The window forgets, but the attempt count does not: a stall that has
    /// scrolled out of the window must still be visible as a refusal rate.
    func testWindowIsBoundedWhileAttemptsKeepCounting() {
        let tracker = LatencyTracker(name: "stage")
        let overflow = LatencyTracker.capacity + 44
        for _ in 0..<overflow { tracker.record(microseconds: 1_000) }

        let summary = try! XCTUnwrap(tracker.summary())
        XCTAssertEqual(summary.samples, LatencyTracker.capacity)
        XCTAssertEqual(summary.attempts, UInt64(overflow))
    }

    /// The point of the type: a link falling behind shows flat timings and a
    /// climbing refusal count, so a refusal must never be recorded as a fast
    /// sample.
    func testRefusalsCountAsAttemptsButNotAsTimings() {
        let tracker = LatencyTracker(name: "link.send.data")
        tracker.record(microseconds: 5_000)
        tracker.recordRefusal()
        tracker.recordRefusal()

        let summary = try! XCTUnwrap(tracker.summary())
        XCTAssertEqual(summary.samples, 1)
        XCTAssertEqual(summary.refusals, 2)
        XCTAssertEqual(summary.attempts, 3)
        XCTAssertEqual(summary.medianMs, 5, accuracy: 0.0001)
    }

    func testRefusalsAloneStillProduceASummary() {
        let tracker = LatencyTracker(name: "stage")
        tracker.recordRefusal()

        let summary = try! XCTUnwrap(tracker.summary())
        XCTAssertEqual(summary.samples, 0)
        XCTAssertEqual(summary.refusals, 1)
        XCTAssertEqual(summary.worstMs, 0)
    }

    func testUntouchedTrackerHasNothingToSay() {
        XCTAssertNil(LatencyTracker(name: "stage").summary())
    }

    func testResetClearsTimingsAndRefusals() {
        let tracker = LatencyTracker(name: "stage")
        tracker.record(microseconds: 1_000)
        tracker.recordRefusal()
        tracker.reset()

        XCTAssertNil(tracker.summary())
    }

    /// A clock that stepped backwards must not turn into an enormous unsigned
    /// duration in the middle of a window.
    func testNonPositiveAndNonFiniteSecondsRecordZeroRatherThanGarbage() {
        let tracker = LatencyTracker(name: "stage")
        tracker.record(seconds: 0.5)
        tracker.record(seconds: -1)
        tracker.record(seconds: .nan)
        tracker.record(seconds: .infinity)

        let summary = try! XCTUnwrap(tracker.summary())
        XCTAssertEqual(summary.samples, 4)
        XCTAssertEqual(summary.worstMs, 500, accuracy: 0.0001)
    }

    func testLatencyClockIsMonotonicAndNeverNegative() {
        let clock = LatencyClock()
        let first = clock.elapsedMicroseconds
        let second = clock.elapsedMicroseconds
        XCTAssertGreaterThanOrEqual(second, first)
    }

    /// The API deliberately has no content-bearing parameter: a tracker is
    /// given a stage name and a number, never a payload. Keep the sentinel
    /// local and prove it cannot reach a summary or its rendered line.
    func testSentinelSecretsNeverAppearInCapturedOutput() {
        let secret = "QR_SECRET_SENTINEL"
        let tracker = LatencyTracker(name: "voice.encode")
        tracker.record(microseconds: UInt32(secret.utf8.count))
        tracker.recordRefusal()

        let summary = try! XCTUnwrap(tracker.summary())
        XCTAssertFalse(String(describing: summary).contains(secret))
        XCTAssertFalse(summary.line.contains(secret))
    }
}
