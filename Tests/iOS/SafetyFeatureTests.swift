import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

final class SafetyFeatureTests: XCTestCase {
    private let voiceQueue = DispatchQueue(label: "test.voice")

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

    func testDefaultMotionFilterRegistersSlowAiming() {
        var filter = MotionPointerFilter(configuration: MotionFilterConfiguration())
        filter.setClutch(active: true)
        XCTAssertNil(filter.process(MotionSample(timestamp: 0, attitude: .identity)))
        // 5 deg/s at 100 Hz is 0.0009 rad per sample. Slow aiming must move the pointer.
        let half = 0.0009 / 2
        let slow = filter.process(MotionSample(
            timestamp: 0.01,
            attitude: MotionQuaternion(w: cos(half), x: 0, y: 0, z: sin(half))
        ))
        XCTAssertGreaterThan(abs(slow?.x ?? 0), 0.5)
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
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log)
        let lifecycle = PhoneLifecycleCoordinator(audio: controller)
        _ = lifecycle.handle(.startup)
        XCTAssertEqual(press(controller), .notForeground)
        _ = lifecycle.handle(.foreground)
        XCTAssertEqual(press(controller), .started)
        XCTAssertTrue(microphone.running)
        controller.pushToTalkReleased()
        voiceQueue.sync {}
        XCTAssertFalse(microphone.running)
    }

    func testLifecycleKeepsPushToTalkAvailableAfterDisconnectInForeground() {
        let log = EventLog()
        let controller = makeController(microphone: TestMicrophone(log: log), log: log)
        let lifecycle = PhoneLifecycleCoordinator(audio: controller)
        _ = lifecycle.handle(.foreground)
        _ = lifecycle.handle(.transportDisconnected)
        XCTAssertEqual(press(controller), .started)
        controller.pushToTalkReleased()
        voiceQueue.sync {}
    }

    func testAudioRequiresLocalPressAndStopsOnRelease() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log, permissionGranted: false)
        XCTAssertEqual(press(controller), .permissionDenied)
        controller.setPermissionGranted(true)
        XCTAssertEqual(press(controller), .started)
        microphone.emit(Array(repeating: Int16(1_000), count: 640))
        voiceQueue.sync {}
        XCTAssertEqual(controller.state, .capturing)
        XCTAssertEqual(log.events.last, "chunk(640)")
        controller.pushToTalkReleased()
        voiceQueue.sync {}
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(microphone.running)
    }

    func testStartCallbackFiresBeforeMicrophoneStarts() {
        let log = EventLog()
        let controller = makeController(microphone: TestMicrophone(log: log), log: log)
        XCTAssertEqual(press(controller), .started)
        XCTAssertEqual(log.events, ["start", "mic_start"])
    }

    func testReleaseFlushesRemainderThenEndsThenStopsMicrophone() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log, samplesPerChunk: 4)
        XCTAssertEqual(press(controller), .started)
        microphone.emit([1, 2, 3, 4, 5, 6, 7])
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "chunk(4)"])
        controller.pushToTalkReleased()
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "chunk(4)", "chunk(3)", "end", "mic_stop"])
        XCTAssertEqual(controller.state, .idle)
    }

    func testInterruptionEndsUtteranceWithEndFrame() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log)
        XCTAssertEqual(press(controller), .started)
        controller.interruptionBegan()
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "end", "mic_stop", "mic_suspend"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(microphone.running)
    }

    func testBackgroundSendsEndBeforeTransportDisconnects() {
        let log = EventLog()
        let controller = makeController(microphone: TestMicrophone(log: log), log: log)
        let lifecycle = PhoneLifecycleCoordinator(
            audio: controller,
            disconnectTransport: { log.events.append("disconnect") }
        )
        _ = lifecycle.handle(.foreground)
        XCTAssertEqual(press(controller), .started)
        _ = lifecycle.handle(.background)
        XCTAssertEqual(log.events, ["start", "mic_start", "end", "mic_stop", "mic_suspend", "disconnect"])
    }

    func testDroppedVoiceMessageLeavesSequenceGapAndNoPartialMessage() throws {
        let session = try PairingSession(key: SymmetricKey(size: .bits256), sessionID: Data(repeating: 7, count: 16))
        let uplink = VoiceUplink(queue: voiceQueue)
        uplink.setSession(session, maximumValueLength: BLEFramingLimits.minimumValueLength)
        let delivered = DeliveryLog()
        uplink.deliver = { fragments, flags in delivered.messages.append((fragments, flags)) }
        voiceQueue.sync {
            uplink.beginStream()
            uplink.send(samples: Array(repeating: 1_000, count: 640))
            uplink.send(samples: Array(repeating: -1_000, count: 640))
            uplink.endStream()
        }
        XCTAssertEqual(delivered.messages.count, 4)
        XCTAssertGreaterThan(delivered.messages[1].fragments.count, 1)

        // The transport drops the second data message whole; the Mac still
        // sees a clean sequence gap and no partial message.
        let kept = [delivered.messages[0], delivered.messages[1], delivered.messages[3]]
        let reassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var frames: [VoiceStreamFrame] = []
        for message in kept {
            for fragment in message.fragments {
                if case let .complete(payload, _, _, _) = try reassembler.append(fragment) {
                    frames.append(try VoiceStreamFrame.decode(session.decrypt(payload).plaintext))
                }
            }
        }
        XCTAssertEqual(frames.map(\.sequence), [0, 1, 3])
        XCTAssertEqual(frames.map(\.isStart), [true, false, false])
        XCTAssertEqual(frames.map(\.isEnd), [false, false, true])
        XCTAssertEqual(frames[1].sampleCount, 640)
        XCTAssertEqual(frames.map(\.streamID), Array(repeating: frames[0].streamID, count: 3))
    }

    private func makeController(
        microphone: TestMicrophone,
        log: EventLog,
        samplesPerChunk: Int = 640,
        permissionGranted: Bool = true,
        releaseGrace: TimeInterval = 0
    ) -> LocalPushToTalkAudioController {
        let controller = LocalPushToTalkAudioController(
            microphone: microphone,
            queue: voiceQueue,
            chunker: PCM16Chunker(samplesPerChunk: samplesPerChunk),
            permissionGranted: permissionGranted,
            releaseGrace: releaseGrace
        )
        controller.onUtteranceStart = { log.events.append("start") }
        controller.onChunk = { log.events.append("chunk(\($0.count))") }
        controller.onUtteranceEnd = { log.events.append("end") }
        return controller
    }

    private func press(_ controller: LocalPushToTalkAudioController) -> AudioCaptureStartResult {
        let result = ResultBox()
        controller.pushToTalkPressed { result.value = $0 }
        voiceQueue.sync {}
        return result.value!
    }

    func testReleaseGraceKeepsCapturingAcrossAQuickRepress() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log, releaseGrace: 0.05)

        XCTAssertEqual(press(controller), .started)
        controller.pushToTalkReleased()
        voiceQueue.sync {}
        XCTAssertEqual(press(controller), .started)
        Thread.sleep(forTimeInterval: 0.1)
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start"])

        controller.pushToTalkReleased()
        Thread.sleep(forTimeInterval: 0.1)
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "end", "mic_stop"])
    }

    func testBackgroundStopsInsideTheGraceWindowAndSuspendsTheMicrophone() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log, releaseGrace: 10)

        XCTAssertEqual(press(controller), .started)
        controller.pushToTalkReleased()
        controller.applicationDidEnterBackground()
        XCTAssertEqual(log.events, ["start", "mic_start", "end", "mic_stop", "mic_suspend"])
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

private final class EventLog: @unchecked Sendable {
    var events: [String] = []
}

private final class ResultBox: @unchecked Sendable {
    var value: AudioCaptureStartResult?
}

private final class DeliveryLog: @unchecked Sendable {
    var messages: [(fragments: [Data], flags: VoiceStreamFlags)] = []
}

private final class TestMicrophone: MicrophoneInputProviding, @unchecked Sendable {
    private let log: EventLog
    private(set) var running = false
    private var callback: (([Int16]) -> Void)?

    init(log: EventLog) {
        self.log = log
    }

    func requestPermission(completion: @escaping (Bool) -> Void) { completion(true) }
    func start(samples: @escaping ([Int16]) -> Void) throws {
        log.events.append("mic_start")
        running = true
        callback = samples
    }
    func stop() {
        log.events.append("mic_stop")
        running = false
        callback = nil
    }
    func suspend() {
        log.events.append("mic_suspend")
    }
    func emit(_ samples: [Int16]) {
        callback?(samples)
    }
}
