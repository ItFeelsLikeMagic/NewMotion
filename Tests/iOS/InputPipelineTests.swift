import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

/// A link that records what the pipeline hands it and can refuse on demand,
/// which is what a busy radio does.
@MainActor
private final class FakeInputLink: InputLink {
    var isReady = true
    var onReadyToSend: (() -> Void)?
    var result: InputSendResult = .sent
    private(set) var sent: [(message: InputMessage, delivery: InputDelivery)] = []

    func send(_ message: InputMessage, delivery: InputDelivery) -> InputSendResult {
        guard result == .sent else { return result }
        sent.append((message, delivery))
        return .sent
    }

    var travelItems: [[PointerStreamItem]] {
        sent.compactMap { entry in
            guard case let .compact(body, _) = entry.message else { return nil }
            return try? PointerStreamFrame.decode(body).items
        }
    }

    var payloads: [MessagePayload] {
        sent.compactMap { entry in
            guard case let .payload(payload) = entry.message else { return nil }
            return payload
        }
    }

    var heartbeats: [HeartbeatPayload] {
        payloads.compactMap { payload in
            guard case let .heartbeat(value) = payload else { return nil }
            return value
        }
    }
}

@MainActor
final class InputPipelineTests: XCTestCase {
    /// The held set is folded from what actually went out, so the two things
    /// the remote can hold are the two it counts.
    func testHeldInputTracksTheDragButtonAndTheWalkModifier() {
        var held = HeldRemoteInput()
        XCTAssertTrue(held.isEmpty)

        held.record(.mouseButton(MouseButtonPayload(button: .left, isDown: true, clickCount: 2)))
        XCTAssertEqual(held.buttons, .left)

        held.record(.tabWalk(TabWalkPayload(phase: .begin, modifier: .command)))
        held.record(.tabWalk(TabWalkPayload(phase: .next, modifier: .command)))
        XCTAssertEqual(held.modifiers, .command)

        // A click and a hotkey carry their own release, so they hold nothing.
        held.record(.mouseDoubleClick(MouseDoubleClickPayload(button: .left)))
        held.record(.hotkey(HotkeyPayload(action: .copy)))
        XCTAssertEqual(held.buttons, .left)
        XCTAssertEqual(held.modifiers, .command)

        held.record(.tabWalk(TabWalkPayload(phase: .commit, modifier: .command)))
        held.record(.mouseButton(MouseButtonPayload(button: .left, isDown: false)))
        XCTAssertTrue(held.isEmpty)
    }

    func testHeartbeatsBeatOnlyWhileSomethingIsHeld() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        uplink.send(.leftClick)
        XCTAssertTrue(link.heartbeats.isEmpty, "a click holds nothing")

        // The drag press starts the beat at once, so the Mac arms immediately
        // rather than a beat later.
        uplink.send(.dragBegan(clickCount: 2))
        XCTAssertEqual(link.heartbeats.count, 1)
        XCTAssertEqual(link.heartbeats[0].heldButtons, .left)
        XCTAssertEqual(link.heartbeats[0].heartbeatIntervalMs, InputUplink.heartbeatIntervalMs)
        XCTAssertTrue(uplink.heldInput.buttons.contains(.left))

        // A beat is worthless once stale, so it never queues behind real input.
        let beat = link.sent.last { if case .payload(.heartbeat) = $0.message { return true }; return false }
        XCTAssertEqual(beat?.delivery, .latestWins)

        uplink.send(.dragEnded)
        XCTAssertTrue(uplink.heldInput.isEmpty)
    }

    /// Recording a press the link refused would make the Mac press it down on
    /// the next beat, because reconcile repairs a difference either way.
    func testARefusedPressIsNotCountedAsHeld() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        link.result = .unavailable
        uplink.send(.dragBegan(clickCount: 2))
        XCTAssertTrue(uplink.heldInput.isEmpty)
        XCTAssertTrue(link.heartbeats.isEmpty)
    }

    /// A link that has gone cannot release anything, and the Mac lets go of
    /// everything when the session drops.
    func testLosingTheLinkDropsTheHeldSet() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        uplink.send(.dragBegan(clickCount: 2))
        XCTAssertFalse(uplink.heldInput.isEmpty)

        uplink.reset()
        XCTAssertTrue(uplink.heldInput.isEmpty)
    }

    func testTravelRidesTheCompactFrameAndKeepsItsRemainder() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        // A fifth of a point at a time: nothing goes out until they make one.
        uplink.send(.pointer(CursorDelta(x: 0.2, y: 0)))
        uplink.send(.pointer(CursorDelta(x: 0.2, y: 0)))
        XCTAssertTrue(link.sent.isEmpty)

        uplink.send(.pointer(CursorDelta(x: 0.2, y: 0)))
        XCTAssertEqual(link.travelItems.count, 1)
        XCTAssertEqual(link.travelItems[0].first?.deltaX, 1)
        // Travel is the caller's to keep, so the link may refuse it.
        XCTAssertEqual(link.sent[0].delivery, .latestWins)

    }

    func testClickQueuesTravelThatIsStillWaitingSoItCannotArriveFirst() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        // The radio was busy, so this travel is still in hand.
        link.result = .busy
        uplink.send(.pointer(CursorDelta(x: 7, y: 0)))
        XCTAssertTrue(link.sent.isEmpty)

        link.result = .sent
        uplink.send(.leftClick)

        // Travel goes first and queues, so the click cannot overtake it.
        XCTAssertEqual(link.sent.count, 3)
        guard case .compact = link.sent[0].message else { return XCTFail("expected travel first") }
        XCTAssertEqual(link.sent[0].delivery, .ordered)
        XCTAssertEqual(link.payloads.count, 2)
        XCTAssertEqual(link.sent[1].delivery, .ordered)
    }

    func testBusyLinkKeepsTheTravelAndSendsItOnceThereIsRoom() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        link.result = .busy
        uplink.send(.pointer(CursorDelta(x: 4, y: 2)))
        uplink.send(.pointer(CursorDelta(x: 3, y: 1)))
        XCTAssertTrue(link.sent.isEmpty)

        // The radio frees up: the whole sum goes, not just the last delta.
        link.result = .sent
        link.onReadyToSend?()
        XCTAssertEqual(link.travelItems.count, 1)
        XCTAssertEqual(link.travelItems[0].first?.deltaX, 7)
        XCTAssertEqual(link.travelItems[0].first?.deltaY, 3)
    }

    func testTravelIsDroppedWhenTheLinkGoesAway() {
        let link = FakeInputLink()
        let uplink = InputUplink(link: link)

        link.result = .unavailable
        uplink.send(.pointer(CursorDelta(x: 9, y: 9)))

        link.result = .sent
        uplink.send(.pointer(CursorDelta(x: 1, y: 0)))
        // Only the travel from after the drop, never the stale nine points.
        XCTAssertEqual(link.travelItems.count, 1)
        XCTAssertEqual(link.travelItems[0].first?.deltaX, 1)
    }

    func testScrollGlideDialSpansOffToLongCoast() {
        // 0 is off, and the middle of the dial keeps the feel the glide
        // shipped with, so an existing setting is not silently retuned.
        let none = ScrollMomentumDriver.configuration(for: 0)
        let middle = ScrollMomentumDriver.configuration(
            for: TrackpadTouchCaptureView.defaultMomentumStrength
        )
        let full = ScrollMomentumDriver.configuration(for: 1)

        XCTAssertLessThan(none.retainedPerSecond, middle.retainedPerSecond)
        XCTAssertLessThan(middle.retainedPerSecond, full.retainedPerSecond)
        XCTAssertEqual(middle.retainedPerSecond, 0.0316, accuracy: 0.002)
    }

    func testScrollSpeedReachesTheGestureEngine() {
        var engine = TrackpadGestureEngine()
        engine.setSensitivity(scroll: 3)
        XCTAssertEqual(engine.configuration.scrollSensitivity, 3)
        // Out of range values are clamped, never applied raw.
        engine.setSensitivity(scroll: 99)
        XCTAssertEqual(engine.configuration.scrollSensitivity, 10)
    }

    func testBothSensorsShareOnePacedStream() {
        let mixer = CursorMixer()
        var events: [RemoteInputEvent] = []
        var deferred: [() -> Void] = []
        mixer.onEvent = { events.append($0) }
        mixer.travelCoalescer.now = { 0 }
        mixer.travelCoalescer.execute = { _, work in deferred.append(work) }

        mixer.handleTravel(CursorDelta(x: 1.5, y: 0))
        mixer.handle([.pointer(CursorDelta(x: 2, y: 1))])
        mixer.handleTravel(CursorDelta(x: 0.5, y: 0))

        XCTAssertEqual(deferred.count, 1)
        deferred.removeFirst()()
        XCTAssertEqual(events, [.pointer(CursorDelta(x: 4, y: 1))])
    }
}
