import Foundation
import XCTest
@testable import NewMotionShared

final class PointerStreamTests: XCTestCase {
    func testRoundTripCarriesEveryItem() throws {
        let frame = try PointerStreamFrame(items: [
            PointerStreamItem(kind: .pointer, deltaX: 18, deltaY: -7),
            PointerStreamItem(kind: .scroll, deltaX: 0, deltaY: 240)
        ])
        let decoded = try PointerStreamFrame.decode(frame.encode())
        XCTAssertEqual(decoded, frame)
    }

    func testExtremeDeltasSurviveEncoding() throws {
        let frame = try PointerStreamFrame(items: [
            PointerStreamItem(kind: .pointer, deltaX: Int16.min, deltaY: Int16.max)
        ])
        XCTAssertEqual(try PointerStreamFrame.decode(frame.encode()), frame)
    }

    /// The whole point of the frame is that it costs a fraction of the JSON
    /// envelope, which is what the BLE link could not keep up with.
    func testOneDeltaIsFarSmallerThanTheJSONEnvelope() throws {
        let frame = try PointerStreamFrame(items: [
            PointerStreamItem(kind: .pointer, deltaX: 4, deltaY: -3)
        ])
        let sessionID = try SessionID(bytes: Array(repeating: 0x21, count: SessionID.byteCount))
        let envelope = ProtocolEnvelope(
            sessionID: sessionID,
            sequence: 1,
            timestampMs: 1_770_000_000_000,
            payload: .pointerDelta(PointerDeltaPayload(deltaX: 4, deltaY: -3))
        )
        let json = try ProtocolCodec.encode(envelope)
        XCTAssertEqual(frame.encode().count, 11)
        XCTAssertLessThan(frame.encode().count * 10, json.count)
    }

    func testMalformedFramesAreRejected() throws {
        let frame = try PointerStreamFrame(items: [
            PointerStreamItem(kind: .pointer, deltaX: 1, deltaY: 1)
        ])
        var wrongMagic = frame.encode()
        wrongMagic[0] = 0x00
        XCTAssertThrowsError(try PointerStreamFrame.decode(wrongMagic))

        var wrongVersion = frame.encode()
        wrongVersion[4] = 9
        XCTAssertThrowsError(try PointerStreamFrame.decode(wrongVersion))

        var wrongKind = frame.encode()
        wrongKind[6] = 7
        XCTAssertThrowsError(try PointerStreamFrame.decode(wrongKind))

        var truncated = frame.encode()
        truncated.removeLast()
        XCTAssertThrowsError(try PointerStreamFrame.decode(truncated))

        var overCounted = frame.encode()
        overCounted[5] = 2
        XCTAssertThrowsError(try PointerStreamFrame.decode(overCounted))

        XCTAssertThrowsError(try PointerStreamFrame(items: []))
        XCTAssertThrowsError(try PointerStreamFrame(items: Array(
            repeating: PointerStreamItem(kind: .pointer, deltaX: 1, deltaY: 1),
            count: PointerStreamFrame.maximumItems + 1
        )))
    }

    /// A cursor frame must fit one notification, or the busy-link retry has to
    /// fall back to queueing whole messages.
    func testBatchedFrameFitsOneNotificationAtATypicalMTU() throws {
        let frame = try PointerStreamFrame(items: [
            PointerStreamItem(kind: .pointer, deltaX: 9, deltaY: 9),
            PointerStreamItem(kind: .scroll, deltaX: 0, deltaY: 9)
        ])
        let fragments = try BLEFragmenter().fragment(
            payload: Data(count: 60) + frame.encode(),
            kind: .data,
            reliable: false,
            messageID: 3,
            maximumValueLength: 185
        )
        XCTAssertEqual(fragments.count, 1)
    }
}
