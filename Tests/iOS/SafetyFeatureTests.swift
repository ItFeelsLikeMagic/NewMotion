import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

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
        XCTAssertEqual(pointer, [.pointer(CursorDelta(x: 10, y: 3))])
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
        ]), [.scroll(ScrollDelta(x: 0, y: 20))])
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

    /// The press after a tap is ambiguous until it either lifts or travels.
    /// Lifting keeps it a double click; travelling makes it a drag.
    func testChainedPressStaysADoubleClickUntilItTravels() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.1)]), [.leftClick])

        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.2)])
        XCTAssertFalse(engine.isDragging)
        // A wobble under the tap threshold is not yet a drag.
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 2, y: 0), phase: .moved, timestamp: 0.21)]), [])
        XCTAssertFalse(engine.isDragging)
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 2, y: 0), phase: .ended, timestamp: 0.22)]), [.doubleClick])
    }

    func testTapAndAHalfDragsWithTheSecondClickCount() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.1)]), [.leftClick])

        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.2)])
        // The travel spent deciding belongs to the drag, so it goes out with it.
        XCTAssertEqual(
            engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 20, y: 0), phase: .moved, timestamp: 0.25)]),
            [.dragBegan(clickCount: 2), .pointer(CursorDelta(x: 20, y: 0))]
        )
        XCTAssertTrue(engine.isDragging)
        XCTAssertEqual(
            engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 30, y: 0), phase: .moved, timestamp: 0.3)]),
            [.pointer(CursorDelta(x: 10, y: 0))]
        )
    }

    /// Three taps in a run make the drag a line selection, the way a Mac reads
    /// a triple click.
    func testThirdPressInARunDragsByLine() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.05)])
        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.1)])
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.15)]), [.doubleClick])

        _ = engine.handle([TrackpadTouch(id: 3, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.2)])
        XCTAssertEqual(
            engine.handle([TrackpadTouch(id: 3, location: TrackpadPoint(x: 20, y: 0), phase: .moved, timestamp: 0.25)]).first,
            .dragBegan(clickCount: 3)
        )
    }

    /// The glass runs out before a long selection does, so a finger back down
    /// inside the grace window continues the same drag rather than starting a
    /// new one.
    func testDragSurvivesAQuickLiftAndEndsWhenTheGraceRunsOut() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.05)])
        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.1)])
        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 40, y: 0), phase: .moved, timestamp: 0.15)])
        XCTAssertTrue(engine.isDragging)

        // The lift holds the button down instead of releasing it.
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 40, y: 0), phase: .ended, timestamp: 0.2)]), [])
        XCTAssertTrue(engine.isDragSuspended)
        XCTAssertEqual(engine.flushSuspendedDrag(at: 0.3), [])

        // Back down inside the window: no second press, and travel resumes.
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 3, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.35)]), [])
        XCTAssertFalse(engine.isDragSuspended)
        XCTAssertEqual(
            engine.handle([TrackpadTouch(id: 3, location: TrackpadPoint(x: 15, y: 0), phase: .moved, timestamp: 0.4)]),
            [.pointer(CursorDelta(x: 15, y: 0))]
        )

        // This time nothing comes back, so the button is released.
        XCTAssertEqual(engine.handle([TrackpadTouch(id: 3, location: TrackpadPoint(x: 15, y: 0), phase: .ended, timestamp: 0.45)]), [])
        XCTAssertEqual(engine.flushSuspendedDrag(at: 0.75), [.dragEnded])
        XCTAssertFalse(engine.isDragging)
        XCTAssertEqual(engine.flushSuspendedDrag(at: 1.0), [])
    }

    func testSuspendedDragIsReleasedByBackgroundAndCancel() {
        for lifecycle in [TrackpadLifecycle.background, .cancel] {
            var engine = TrackpadGestureEngine()
            _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
            _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.05)])
            _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.1)])
            _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 40, y: 0), phase: .moved, timestamp: 0.15)])
            _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 40, y: 0), phase: .ended, timestamp: 0.2)])
            XCTAssertTrue(engine.isDragSuspended)
            XCTAssertEqual(engine.handle(lifecycle), [.dragEnded])
            XCTAssertFalse(engine.isDragging)
        }
    }

    func testSecondFingerDuringADragReleasesTheButton() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.05)])
        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0.1)])
        _ = engine.handle([TrackpadTouch(id: 2, location: TrackpadPoint(x: 40, y: 0), phase: .moved, timestamp: 0.15)])
        XCTAssertEqual(
            engine.handle([TrackpadTouch(id: 3, location: TrackpadPoint(x: 80, y: 0), phase: .began, timestamp: 0.2)]),
            [.dragEnded]
        )
        XCTAssertFalse(engine.isDragging)
    }

    /// A press that is not chained to a tap moves the cursor, exactly as before.
    func testAPressOnItsOwnStillMovesTheCursor() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)])
        XCTAssertEqual(
            engine.handle([TrackpadTouch(id: 1, location: TrackpadPoint(x: 20, y: 0), phase: .moved, timestamp: 0.05)]),
            [.pointer(CursorDelta(x: 20, y: 0))]
        )
        XCTAssertFalse(engine.isDragging)
    }

    func testTwoFingerTapSurvivesAnUnevenLift() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0),
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 12, y: 0), phase: .began, timestamp: 0)
        ])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .ended, timestamp: 0.05)
        ]), [])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 12, y: 0), phase: .ended, timestamp: 0.07)
        ]), [.rightClick])
    }

    func testScrollingFingerLeftBehindDoesNotMoveThePointer() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0),
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 12, y: 0), phase: .began, timestamp: 0)
        ])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 40), phase: .moved, timestamp: 0.02),
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 12, y: 40), phase: .moved, timestamp: 0.02)
        ]), [.scroll(ScrollDelta(x: 0, y: 40))])

        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 40), phase: .ended, timestamp: 0.04)
        ])
        // The finger still down would otherwise drag the cursor.
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 30, y: 60), phase: .moved, timestamp: 0.06)
        ]), [])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 30, y: 60), phase: .ended, timestamp: 0.08)
        ]), [])
    }

    func testSecondTapIsADoubleClickOnlyWhenItIsQuickAndClose() {
        var engine = TrackpadGestureEngine()
        func tap(_ id: UInt64, at point: TrackpadPoint, start: TimeInterval) -> [RemoteInputEvent] {
            _ = engine.handle([TrackpadTouch(id: id, location: point, phase: .began, timestamp: start)])
            return engine.handle([TrackpadTouch(id: id, location: point, phase: .ended, timestamp: start + 0.05)])
        }

        XCTAssertEqual(tap(1, at: TrackpadPoint(x: 5, y: 5), start: 0), [.leftClick])
        XCTAssertEqual(tap(2, at: TrackpadPoint(x: 6, y: 5), start: 0.15), [.doubleClick])
        // A third tap starts a new count rather than chaining double clicks.
        XCTAssertEqual(tap(3, at: TrackpadPoint(x: 6, y: 5), start: 0.3), [.leftClick])
        // Too far away, and too late, are both ordinary clicks.
        XCTAssertEqual(tap(4, at: TrackpadPoint(x: 90, y: 90), start: 0.45), [.leftClick])
        XCTAssertEqual(tap(5, at: TrackpadPoint(x: 90, y: 90), start: 1.5), [.leftClick])
    }

    func testThreeFingerSwipeUpOpensMissionControlOnceAndNeverScrolls() {
        var engine = TrackpadGestureEngine()
        func fingers(_ y: Double, phase: TrackpadTouchPhase, at timestamp: TimeInterval) -> [TrackpadTouch] {
            [0, 1, 2].map { index in
                TrackpadTouch(
                    id: UInt64(index + 1),
                    location: TrackpadPoint(x: 20 + Double(index) * 30, y: y),
                    phase: phase,
                    timestamp: timestamp
                )
            }
        }

        XCTAssertEqual(engine.handle(fingers(300, phase: .began, at: 0)), [])
        // Short of the threshold nothing is sent, and never a scroll.
        XCTAssertEqual(engine.handle(fingers(280, phase: .moved, at: 0.02)), [])
        XCTAssertEqual(engine.handle(fingers(250, phase: .moved, at: 0.04)), [.missionControl])
        // One swipe is one Mission Control, however far the hand keeps going.
        XCTAssertEqual(engine.handle(fingers(180, phase: .moved, at: 0.06)), [])
        // A staggered lift must not leak a scroll or a click.
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 20, y: 180), phase: .ended, timestamp: 0.08)
        ]), [])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 50, y: 160), phase: .moved, timestamp: 0.09)
        ]), [])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 50, y: 160), phase: .ended, timestamp: 0.10),
            TrackpadTouch(id: 3, location: TrackpadPoint(x: 80, y: 180), phase: .ended, timestamp: 0.10)
        ]), [])
    }

    func testThreeFingersPickMissionControlOrAppWindowsByDirection() {
        func gesture(dx: Double, dy: Double) -> [RemoteInputEvent] {
            var engine = TrackpadGestureEngine()
            func fingers(_ offset: Double, phase: TrackpadTouchPhase, at timestamp: TimeInterval) -> [TrackpadTouch] {
                [0, 1, 2].map { index in
                    TrackpadTouch(
                        id: UInt64(index + 1),
                        location: TrackpadPoint(x: 20 + Double(index) * 30 + dx * offset, y: 300 + dy * offset),
                        phase: phase,
                        timestamp: timestamp
                    )
                }
            }
            _ = engine.handle(fingers(0, phase: .began, at: 0))
            var outputs = engine.handle(fingers(1, phase: .moved, at: 0.03))
            outputs += engine.handle(fingers(1, phase: .ended, at: 0.05))
            return outputs
        }

        XCTAssertEqual(gesture(dx: 0, dy: -80), [.missionControl])
        XCTAssertEqual(gesture(dx: 0, dy: 80), [.appExpose])
        // Sideways means something else on a Mac, so it stays unclaimed.
        XCTAssertEqual(gesture(dx: 80, dy: -20), [])
        XCTAssertEqual(gesture(dx: -80, dy: 20), [])
    }

    func testThreeFingerTapIsNotARightClick() {
        var engine = TrackpadGestureEngine()
        let points = [TrackpadPoint(x: 20, y: 300), TrackpadPoint(x: 50, y: 300), TrackpadPoint(x: 80, y: 300)]
        let began = points.enumerated().map {
            TrackpadTouch(id: UInt64($0.offset + 1), location: $0.element, phase: .began, timestamp: 0)
        }
        let ended = points.enumerated().map {
            TrackpadTouch(id: UInt64($0.offset + 1), location: $0.element, phase: .ended, timestamp: 0.06)
        }
        XCTAssertEqual(engine.handle(began), [])
        XCTAssertEqual(engine.handle(ended), [])
    }

    func testThreeFingerSwipesReachTheSharedProtocolAsHotkeys() throws {
        XCTAssertEqual(
            try SharedTrackpadProtocolAdapter.payloads(for: .missionControl),
            [.hotkey(HotkeyPayload(action: .missionControl))]
        )
        XCTAssertEqual(
            try SharedTrackpadProtocolAdapter.payloads(for: .appExpose),
            [.hotkey(HotkeyPayload(action: .appExpose))]
        )
    }

    func testScrollMomentumCoastsThenStops() {
        var momentum = ScrollMomentum()
        XCTAssertFalse(momentum.begin(velocity: 10))
        XCTAssertFalse(momentum.isActive)

        XCTAssertTrue(momentum.begin(velocity: 1_200))
        let first = momentum.step(elapsed: 1.0 / 60)
        XCTAssertEqual(first?.y ?? 0, 20, accuracy: 0.001)
        let second = momentum.step(elapsed: 1.0 / 60)
        XCTAssertLessThan(second?.y ?? 0, first?.y ?? 0)

        var frames = 0
        while momentum.step(elapsed: 1.0 / 60) != nil {
            frames += 1
            XCTAssertLessThan(frames, 600)
        }
        XCTAssertFalse(momentum.isActive)

        XCTAssertTrue(momentum.begin(velocity: -1_200))
        XCTAssertLessThan(momentum.step(elapsed: 1.0 / 60)?.y ?? 0, 0)
        momentum.stop()
        XCTAssertNil(momentum.step(elapsed: 1.0 / 60))
    }

    func testDoubleClickAndCommandTabReachTheSharedProtocol() throws {
        XCTAssertEqual(
            try SharedTrackpadProtocolAdapter.payloads(for: .doubleClick),
            [.mouseDoubleClick(MouseDoubleClickPayload(button: .left))]
        )
        XCTAssertEqual(
            try SharedKeyboardProtocolAdapter.payload(for: .hotkey(.deleteBackward)),
            .hotkey(HotkeyPayload(action: .deleteBackward))
        )
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
        controller.onUtteranceCancel = { log.events.append("cancel") }
        return controller
    }

    func testCancelDropsPendingAudioAndEndsTheStreamAsCancelled() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log, samplesPerChunk: 4)
        XCTAssertEqual(press(controller), .started)
        microphone.emit([1, 2, 3, 4, 5, 6, 7])
        voiceQueue.sync {}
        controller.pushToTalkCancelled()
        voiceQueue.sync {}
        // The three buffered samples never leave, and the stream ends as a cancel.
        XCTAssertEqual(log.events, ["start", "mic_start", "chunk(4)", "cancel", "mic_stop"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(microphone.running)
    }

    @MainActor
    func testDraggingToACancelZoneThrowsTheUtteranceAway() {
        let log = EventLog()
        let (audio, ptt) = makePushToTalk(log: log)
        ptt.pressed()
        voiceQueue.sync {}
        ptt.dragged(to: CGPoint(x: 30, y: 760))
        XCTAssertEqual(ptt.armedZone, .cancelLeading)
        ptt.released()
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "cancel", "mic_stop"])
        XCTAssertEqual(audio.state, .idle)
        XCTAssertNil(ptt.armedZone)
        XCTAssertFalse(ptt.isHolding)
    }

    /// Backing out of the corner puts the utterance back on its normal path.
    @MainActor
    func testDraggingBackOutOfACancelZoneStillSends() {
        let log = EventLog()
        let (_, ptt) = makePushToTalk(log: log)
        ptt.pressed()
        voiceQueue.sync {}
        // The corner of the frame is outside the circle drawn inside it.
        ptt.dragged(to: CGPoint(x: 5, y: 705))
        XCTAssertNil(ptt.armedZone)
        ptt.dragged(to: CGPoint(x: 30, y: 760))
        ptt.dragged(to: CGPoint(x: 200, y: 400))
        XCTAssertNil(ptt.armedZone)
        ptt.released()
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "end", "mic_stop"])
    }

    @MainActor
    private func makePushToTalk(log: EventLog) -> (LocalPushToTalkAudioController, PushToTalkController) {
        let audio = makeController(microphone: TestMicrophone(log: log), log: log)
        let ptt = PushToTalkController(audio: audio, activity: { _ in }, logContext: { [:] })
        ptt.setZoneFrame(.cancelLeading, CGRect(x: 0, y: 700, width: 120, height: 120))
        ptt.setZoneFrame(.cancelTrailing, CGRect(x: 280, y: 700, width: 120, height: 120))
        return (audio, ptt)
    }

    func testCancelBeatsTheReleaseGraceWindow() {
        let log = EventLog()
        let controller = makeController(microphone: TestMicrophone(log: log), log: log, releaseGrace: 5)
        XCTAssertEqual(press(controller), .started)
        controller.pushToTalkReleased()
        controller.pushToTalkCancelled()
        voiceQueue.sync {}
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(log.events, ["start", "mic_start", "cancel", "mic_stop"])
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

    func testMicrophoneStaysWarmBetweenUtterancesAndIsHandedBackOnBackground() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log)

        XCTAssertEqual(press(controller), .started)
        controller.pushToTalkReleased()
        voiceQueue.sync {}
        XCTAssertEqual(press(controller), .started)
        controller.pushToTalkReleased()
        voiceQueue.sync {}
        XCTAssertEqual(log.events, ["start", "mic_start", "end", "mic_stop", "start", "mic_start", "end", "mic_stop"])

        controller.applicationDidEnterBackground()
        XCTAssertEqual(log.events.last, "mic_suspend")
    }

    func testForegroundPrewarmsTheMicrophoneWithoutOpeningAnUtterance() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log)

        controller.applicationWillEnterForeground()
        voiceQueue.sync {}
        XCTAssertGreaterThan(microphone.prewarmCount, 0)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertFalse(microphone.running)
    }

    func testMicrophoneIsNotPrewarmedBeforePermissionIsGranted() {
        let log = EventLog()
        let microphone = TestMicrophone(log: log)
        let controller = makeController(microphone: microphone, log: log, permissionGranted: false)

        controller.applicationWillEnterForeground()
        voiceQueue.sync {}
        XCTAssertEqual(microphone.prewarmCount, 0)

        controller.setPermissionGranted(true)
        voiceQueue.sync {}
        XCTAssertGreaterThan(microphone.prewarmCount, 0)
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

    func testTrackpadPointerCarriesTheFractionalRemainder() {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)
        ])

        var travelled = 0.0
        for step in 1...100 {
            let outputs = engine.handle([
                TrackpadTouch(
                    id: 1,
                    location: TrackpadPoint(x: Double(step) * 0.3, y: 0),
                    phase: .moved,
                    timestamp: Double(step) * 0.02
                )
            ])
            for case let .pointer(delta) in outputs {
                XCTAssertEqual(delta.x, delta.x.rounded())
                travelled += delta.x
            }
        }
        XCTAssertEqual(travelled, 30)

        // The carry is per gesture: lifting and starting again must not move.
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 30, y: 0), phase: .ended, timestamp: 3)
        ])
        _ = engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 4)
        ])
        XCTAssertEqual(engine.handle([
            TrackpadTouch(id: 2, location: TrackpadPoint(x: 0.3, y: 0), phase: .moved, timestamp: 4.02)
        ]), [])
    }

    func testTrackpadCoalescerSumsPointerDeltasAndKeepsClickOrder() {
        let coalescer = CursorMixer(interval: 0.05)
        var clock = 1.0
        coalescer.travelCoalescer.now = { clock }
        var queued: [(TimeInterval, () -> Void)] = []
        coalescer.travelCoalescer.execute = { delay, work in queued.append((delay, work)) }
        var outputs: [RemoteInputEvent] = []
        coalescer.onEvent = { outputs.append($0) }

        coalescer.handle([.pointer(CursorDelta(x: 1, y: 2))])
        coalescer.handle([.pointer(CursorDelta(x: 3, y: 4))])
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(outputs.isEmpty)

        queued.removeFirst().1()
        XCTAssertEqual(outputs, [.pointer(CursorDelta(x: 4, y: 6))])

        // A click inside the interval flushes the motion that preceded it.
        clock = 1.01
        coalescer.handle([.pointer(CursorDelta(x: 5, y: 0)), .leftClick])
        XCTAssertEqual(outputs, [
            .pointer(CursorDelta(x: 4, y: 6)),
            .pointer(CursorDelta(x: 5, y: 0)),
            .leftClick
        ])
    }

    func testMotionSinkAddsDeltasAndFlushesOnce() {
        let sink = DeltaCoalescer<MotionPointerDelta>.motionPointer()
        sink.minimumInterval = 0
        var queued: [() -> Void] = []
        sink.execute = { _, work in queued.append(work) }
        var received: [MotionPointerDelta] = []
        sink.onFlush = { received.append($0) }

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
        let sink = DeltaCoalescer<MotionPointerDelta>.motionPointer()
        sink.minimumInterval = 0.04
        var clock = 1.0
        sink.now = { clock }
        var queued: [(TimeInterval, () -> Void)] = []
        sink.execute = { delay, work in queued.append((delay, work)) }
        var received: [MotionPointerDelta] = []
        sink.onFlush = { received.append($0) }

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

private final class TestMicrophone: MicrophoneInputProviding, @unchecked Sendable {
    private let log: EventLog
    private(set) var running = false
    private(set) var prewarmCount = 0
    private var callback: (([Int16]) -> Void)?

    init(log: EventLog) {
        self.log = log
    }

    func requestPermission(completion: @escaping (Bool) -> Void) { completion(true) }
    // Counted rather than logged so the utterance event assertions stay exact.
    func prewarm() { prewarmCount += 1 }
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
