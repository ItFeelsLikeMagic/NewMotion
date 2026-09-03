import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

final class IntegrationTests: XCTestCase {
    func testTrackpadOutputTravelsThroughProtocolAndBLEFraming() throws {
        var engine = TrackpadGestureEngine()
        _ = engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 0, y: 0), phase: .began, timestamp: 0)
        ])
        let output = try XCTUnwrap(engine.handle([
            TrackpadTouch(id: 1, location: TrackpadPoint(x: 18, y: -7), phase: .moved, timestamp: 0.02)
        ]).first)
        let payload = try SharedTrackpadProtocolAdapter.payload(for: output)
        let sessionID = try SessionID(bytes: Array(repeating: 0x21, count: SessionID.byteCount))
        let envelope = ProtocolEnvelope(sessionID: sessionID, sequence: 1, timestampMs: 20, payload: payload)
        let encoded = try ProtocolCodec.encode(envelope)
        let frames = try BLEFragmenter().fragment(
            payload: Data(encoded),
            kind: .data,
            reliable: false,
            messageID: 17,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        let reassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var complete: Data?
        for frame in frames {
            if case let .complete(payload, _, _, _) = try reassembler.append(frame) {
                complete = payload
            }
        }
        XCTAssertEqual(try ProtocolCodec.decode(Array(try XCTUnwrap(complete))), envelope)
    }

    func testMotionDeltaTravelsThroughProtocolAndBLEFraming() throws {
        let payload = try SharedMotionProtocolAdapter.payload(
            for: MotionPointerDelta(x: -4, y: 6),
            sampleRateHz: 100
        )
        guard case let .motionPointerDelta(value) = payload else {
            return XCTFail("expected motion payload")
        }
        XCTAssertEqual(value.deltaX, -4)
        XCTAssertEqual(value.deltaY, 6)
        XCTAssertEqual(value.sampleRateHz, 100)

        let sessionID = try SessionID(bytes: Array(repeating: 0x22, count: SessionID.byteCount))
        let envelope = ProtocolEnvelope(sessionID: sessionID, sequence: 2, timestampMs: 10, payload: payload)
        let frames = try BLEFragmenter().fragment(
            payload: Data(try ProtocolCodec.encode(envelope)),
            kind: .data,
            reliable: false,
            messageID: 18,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        let reassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var complete: Data?
        for frame in frames {
            if case let .complete(payload, _, _, _) = try reassembler.append(frame) {
                complete = payload
            }
        }
        XCTAssertEqual(try ProtocolCodec.decode(Array(try XCTUnwrap(complete))), envelope)
    }

    func testTrackpadClickAndScrollExpandToSharedPayloads() throws {
        let click = try SharedTrackpadProtocolAdapter.payloads(for: .leftClick)
        XCTAssertEqual(click.count, 2)
        guard case let .mouseButton(down) = click[0], case let .mouseButton(up) = click[1] else {
            return XCTFail("expected left click down/up")
        }
        XCTAssertEqual(down.button, .left)
        XCTAssertTrue(down.isDown)
        XCTAssertEqual(up.button, .left)
        XCTAssertFalse(up.isDown)

        let scroll = try SharedTrackpadProtocolAdapter.payloads(
            for: .scroll(TrackpadScrollDelta(x: 0, y: 12))
        )
        XCTAssertEqual(scroll.count, 1)
        guard case let .scrollDelta(payload) = scroll[0] else {
            return XCTFail("expected scroll payload")
        }
        XCTAssertEqual(payload.deltaY, 12)
    }

}
