import XCTest
@testable import PhoneRemoteShared

final class ObservabilityTests: XCTestCase {
    func testCountersLatencyAndLifecycleUseInjectedClock() {
        let clock = TestMetricsClock(nowMs: 10)
        let sink = InMemoryMetricsSink()
        let recorder = MetricsRecorder(clock: clock, sink: sink)

        recorder.recordLifecycle(.launched)
        recorder.recordConnectionState(.connected)
        recorder.recordPacketSent(type: .pointerDelta, byteCount: 12)
        recorder.recordPacketReceived(type: .pointerDelta, byteCount: 12)
        recorder.recordSequenceGap(type: .pointerDelta, expected: 4, received: 7)
        recorder.recordDuplicate(type: .pointerDelta)
        recorder.recordRetry(type: .mouseButton)
        recorder.recordAcknowledgement(for: .mouseButton, latencyMs: 51)
        recorder.recordHeartbeatRelease()
        recorder.recordAudioGap()
        recorder.recordAudioDuration(milliseconds: 2_000)
        recorder.recordMotionSample(rateHz: 100)
        recorder.recordMotionOutput(rateHz: 98)

        clock.advance(by: 20)
        recorder.recordLatency(milliseconds: 300)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.counters[.packetsSent], 1)
        XCTAssertEqual(snapshot.counters[.packetsReceived], 1)
        XCTAssertEqual(snapshot.counters[.sequenceGaps], 1)
        XCTAssertEqual(snapshot.counters[.duplicates], 1)
        XCTAssertEqual(snapshot.counters[.retries], 1)
        XCTAssertEqual(snapshot.counters[.acknowledgements], 1)
        XCTAssertEqual(snapshot.counters[.heartbeatReleases], 1)
        XCTAssertEqual(snapshot.counters[.audioGaps], 1)
        XCTAssertEqual(snapshot.counters[.motionSamples], 1)
        XCTAssertEqual(snapshot.counters[.motionOutputs], 1)
        XCTAssertEqual(snapshot.latencyBuckets, [0, 0, 0, 0, 1, 0, 1])
        XCTAssertEqual(snapshot.latestLifecycle, .launched)
        XCTAssertEqual(sink.records.first?.timestampMs, 10)
        XCTAssertEqual(sink.records.last?.timestampMs, 30)
    }

    func testSentinelSecretsNeverAppearInCapturedOutput() {
        let clock = TestMetricsClock()
        let sink = InMemoryMetricsSink()
        let recorder = MetricsRecorder(clock: clock, sink: sink)
        // The API deliberately has no content-bearing parameter. Keep the
        // sentinel local and ensure it cannot leak through a structured event.
        let secret = "QR_SECRET_SENTINEL"
        recorder.recordPacketSent(type: .textInput, byteCount: secret.utf8.count)
        recorder.recordPacketReceived(type: .audioChunk, byteCount: secret.utf8.count)
        recorder.recordLifecycle(.foregrounded)

        XCTAssertFalse(String(describing: sink.records).contains(secret))
        XCTAssertFalse(String(describing: recorder.snapshot()).contains(secret))
    }
}

