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
}

@MainActor
final class InputPipelineTests: XCTestCase {
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
