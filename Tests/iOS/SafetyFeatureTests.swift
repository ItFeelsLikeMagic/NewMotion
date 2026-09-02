import Foundation
import UIKit
import XCTest
@testable import PhoneRemote_iOS

final class SafetyFeatureTests: XCTestCase {
    func testTrackpadPointerScrollClicksAndCancellation() {
        var engine = TrackpadGestureEngine()
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 10, y: 10), phase: .began, timestamp: 0)
        ]), [])
        let pointer = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 20, y: 13), phase: .moved, timestamp: 0.01)
        ])
        XCTAssertEqual(pointer, [.pointer(TrackpadPointerDelta(x: 10, y: 3))])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 20, y: 13), phase: .ended, timestamp: 0.02)
        ]), [])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .moved, timestamp: 0.03)
        ]), [])

        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 1),
            TrackpadTouch(id: 3, location: TrackpadPoint(x: 10, y: 0), phase: .began, timestamp: 1)
        ]), [])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 20), phase: .moved, timestamp: 1.02),
            TrackpadTouch(id: 3, location: TrackpadPoint(x: 10, y: 20), phase: .moved, timestamp: 1.02)
        ]), [.scroll(TrackpadScrollDelta(x: 0, y: 20))])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 20), phase: .ended, timestamp: 1.03),
            TrackpadTouch(id: 3, location: TrackpadPoint(x: 10, y: 20), phase: .ended, timestamp: 1.03)
        ]), [])

        var tapEngine = TrackpadGestureEngine()
        _ = tapEngine.handle([
            TrackpadTouch(id: 4, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 2),
            TrackpadTouch(id: 5, location: TrackpadPoint(x: 10, y: 0), phase: .began, timestamp: 2)
        ])
        XCTAssertEqual(tapEngine.handle([
            TrackpadTouch(id: 4, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 2.05),
            TrackpadTouch(id: 5, location: TrackpadPoint(x: 10, y: 0), phase: .ended, timestamp: 2.05)
        ]), [.rightClick])
    }

    func testDragIsOffByDefaultAndReleasesWhenEnabled() {
        var engine = TrackpadGestureEngine()
        // First tap.
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.1)]), [.leftClick])
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.2)])
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .moved, timestamp: 0.21)]), [])
        XCTAssertFalse(engine.isDragging)
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.22)]), [.leftClick])

        engine.setDragEnabled(true)
        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.3)])
        XCTAssertTrue(engine.isDragging)
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 3, y: 0), phase: .ended, timestamp: 0.31)]), [.dragEnded])
    }

    func testUnicodeChunkingPreservesGraphemesAndBounds() {
        let chunker = UnicodeTextEntryChunker(policy: UnicodeTextEntryPolicy(maximumUTF8Bytes: 32, maximumChunkUTF8Bytes: 8))
        guard case let .chunks(chunks) = chunker.chunk("Aé中🧑‍💻") else {
            return XCTFail("expected chunks")
        }
        XCTAssertEqual(chunks.map(\.value).joined(), "Aé中🧑‍💻")
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        XCTAssertTrue(chunks.allSatisfy { $0.total == chunks.count })
        XCTAssertEqual(chunker.chunk(String(repeating: "x", count: 33)), .rejected(.tooLarge))
    }

    func testMotionSessionClutchAndReference() {
        let provider = SimulatedDeviceMotionProvider()
        let sink = TestMotionSink()
        let session = MotionPointerSession(provider: provider, sink: sink)
        XCTAssertEqual(session.setClutchHeld(true), .inactive)
        XCTAssertEqual(session.setAppActive(true), .started)
        provider.emit(MotionSample(timestamp: 0, attitude: .identity))
        provider.emit(MotionSample(
            timestamp: 0.01,
            attitude: MotionQuaternion(w: cos(0.025), x: 0, y: 0, z: sin(0.025))
        ))
        XCTAssertEqual(sink.values.count, 1)
        XCTAssertLessThan(sink.values[0].x, 0)
        _ = session.setClutchHeld(false)
        provider.emit(MotionSample(timestamp: 0.02, attitude: MotionQuaternion(w: 1, x: 0, y: 0, z: 0.2)))
        XCTAssertEqual(sink.values.count, 1)
    }

    func testMotionFilterNoiseAccelerationAndInvalidGapAreBounded() {
        var filter = MotionPointerFilter(configuration: MotionFilterConfiguration(
            sensitivity: 100,
            deadZoneRadians: 0.01,
            smoothingAlpha: 1,
            accelerationExponent: 1.2,
            accelerationScale: 1,
            maxOutputPerSample: 20,
            maximumSampleGap: 0.2,
            maximumRotationPerSample: 1.0
        ))
        filter.setClutch(active: true)
        XCTAssertNil(filter.process(MotionSample(timestamp: 0, attitude: .identity)))
        // Noise below the dead zone must not move the pointer.
        XCTAssertNil(filter.process(MotionSample(
            timestamp: 0.01,
            attitude: MotionQuaternion(w: cos(0.002), x: 0, y: 0, z: sin(0.002))
        )))
        // A valid slow rotation produces a bounded output.
        let slow = filter.process(MotionSample(
            timestamp: 0.02,
            attitude: MotionQuaternion(w: cos(0.04), x: 0, y: 0, z: sin(0.04))
        ))
        XCTAssertNotNil(slow)
        XCTAssertLessThan(slow?.x ?? 0, 0)
        XCTAssertLessThanOrEqual(abs(slow?.x ?? 0), 20)
        // A sample gap resets the reference and emits nothing.
        XCTAssertNil(filter.process(MotionSample(timestamp: 1, attitude: .identity)))
        XCTAssertEqual(filter.rejectedSampleCount, 1)
        // An extreme one-sample rotation is rejected and remains bounded.
        XCTAssertNil(filter.process(MotionSample(
            timestamp: 1.01,
            attitude: MotionQuaternion(w: cos(1.2), x: 0, y: 0, z: sin(1.2))
        )))
        XCTAssertNil(filter.process(MotionSample(
            timestamp: 1.02,
            attitude: MotionQuaternion(w: cos(2.4), x: 0, y: 0, z: sin(2.4))
        )))
        XCTAssertGreaterThanOrEqual(filter.rejectedSampleCount, 2)
    }

    func testLifecycleForegroundRestoresPushToTalkAfterStartup() {
        let microphone = TestMicrophone()
        let controller = LocalPushToTalkAudioController(microphone: microphone, permissionGranted: true)
        let lifecycle = PhoneLifecycleCoordinator(audio: controller)
        _ = lifecycle.handle(.startup)
        XCTAssertEqual(controller.pushToTalkPressed(), .notForeground)
        _ = lifecycle.handle(.foreground)
        XCTAssertEqual(controller.pushToTalkPressed(), .started)
        XCTAssertTrue(microphone.running)
        controller.pushToTalkReleased()
        XCTAssertFalse(microphone.running)
    }

    func testLifecycleKeepsPushToTalkAvailableAfterDisconnectInForeground() {
        let microphone = TestMicrophone()
        let controller = LocalPushToTalkAudioController(microphone: microphone, permissionGranted: true)
        let lifecycle = PhoneLifecycleCoordinator(audio: controller)
        _ = lifecycle.handle(.foreground)
        _ = lifecycle.handle(.transportDisconnected)
        XCTAssertEqual(controller.pushToTalkPressed(), .started)
        controller.pushToTalkReleased()
    }

    func testAudioRequiresLocalPressAndStopsOnRelease() {
        let microphone = TestMicrophone()
        let controller = LocalPushToTalkAudioController(microphone: microphone, permissionGranted: false)
        XCTAssertEqual(controller.pushToTalkPressed(), .permissionDenied)
        controller.setPermissionGranted(true)
        XCTAssertEqual(controller.pushToTalkPressed(), .started)
        microphone.emit(Array(repeating: Int16(1_000), count: 320), timestamp: 1)
        XCTAssertEqual(controller.state, .capturing)
        XCTAssertEqual(microphone.lastSamples.count, 320)
        controller.pushToTalkReleased()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(microphone.running)
        // No remote activation method exists on the controller by design.
        XCTAssertFalse(controller.isCapturing)
    }

    func testPushToTalkFlushEmitsRemainderAndEnd() {
        let microphone = TestMicrophone()
        let controller = LocalPushToTalkAudioController(
            microphone: microphone,
            chunker: PCM16Chunker(configuration: AudioChunkerConfiguration(samplesPerChunk: 4)),
            permissionGranted: true
        )
        let captured = FlushCapture()
        controller.onChunk = { captured.chunks.append($0) }
        controller.onUtteranceEnd = { captured.ended += 1 }
        XCTAssertEqual(controller.pushToTalkPressed(), .started)
        microphone.emit([1, 2, 3], timestamp: 1)
        XCTAssertTrue(captured.chunks.isEmpty)
        controller.pushToTalkReleased()
        XCTAssertEqual(captured.chunks.count, 1)
        XCTAssertEqual(captured.chunks[0].sampleCount, 3)
        XCTAssertEqual(captured.ended, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTrackpadViewKeepsTouchesFromParentScrolling() {
        let view = TrackpadTouchCaptureView(frame: .zero)
        XCTAssertTrue(view.isExclusiveTouch)
        XCTAssertTrue(view.isMultipleTouchEnabled)
    }

    func testMotionSinkAddsDeltasAndFlushesOnce() {
        let sink = FeatureMotionSink()
        sink.minimumInterval = 0
        var queued: [() -> Void] = []
        sink.execute = { _, work in queued.append(work) }
        var received: [MotionPointerDelta] = []
        sink.onDelta = { received.append($0) }

        sink.send(MotionPointerDelta(x: 1, y: 2))
        sink.send(MotionPointerDelta(x: 3, y: 4))
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(received.isEmpty)

        queued.removeFirst()()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].x, 4)
        XCTAssertEqual(received[0].y, 6)
        XCTAssertTrue(queued.isEmpty)
    }

    func testMotionSinkWaitsOutTheIntervalBeforeASecondFlush() {
        let sink = FeatureMotionSink()
        sink.minimumInterval = 0.04
        var clock = 1.0
        sink.now = { clock }
        var queued: [(TimeInterval, () -> Void)] = []
        sink.execute = { delay, work in queued.append((delay, work)) }
        var received: [MotionPointerDelta] = []
        sink.onDelta = { received.append($0) }

        sink.send(MotionPointerDelta(x: 1, y: 0))
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].0, 0)
        queued.removeFirst().1()
        XCTAssertEqual(received.map(\.x), [1])

        sink.send(MotionPointerDelta(x: 2, y: 0))
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].0, 0)
        queued.removeFirst().1()
        XCTAssertEqual(received.map(\.x), [1])
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].0, 0.04, accuracy: 0.0001)

        clock = 1.04
        queued.removeFirst().1()
        XCTAssertEqual(received.map(\.x), [1, 2])
    }
}

private final class TestMotionSink: MotionPointerOutputSink {
    var values: [MotionPointerDelta] = []
    func send(_ delta: MotionPointerDelta) { values.append(delta) }
}

private final class FlushCapture: @unchecked Sendable {
    var chunks: [CapturedPCM16Chunk] = []
    var ended = 0
}

private final class TestMicrophone: MicrophoneInputProviding {
    var running = false
    var lastSamples: [Int16] = []
    private var callback: (([Int16], TimeInterval) -> Void)?

    func requestPermission(completion: @escaping (Bool) -> Void) { completion(true) }
    func start(samples: @escaping ([Int16], TimeInterval) -> Void) throws {
        running = true
        callback = samples
    }
    func stop() {
        running = false
        callback = nil
    }
    func emit(_ samples: [Int16], timestamp: TimeInterval) {
        lastSamples = samples
        callback?(samples, timestamp)
    }
}
