import Foundation
import XCTest
@testable import PhoneRemoteShared

final class ProtocolTests: XCTestCase {
    private let sessionID = try! SessionID(bytes: Array(repeating: 7, count: SessionID.byteCount))

    func testRoundTripCoversEveryMVPMessageType() throws {
        let audio = try AudioChunkPayload(streamID: sessionID, chunkIndex: 3, pcm: [0, 1, 2, 3])
        let payloads: [MessagePayload] = [
            .heartbeat(HeartbeatPayload(isActive: true, buttons: 1, modifiers: 2)),
            .pointerDelta(PointerDeltaPayload(deltaX: 10, deltaY: -9)),
            .scrollDelta(ScrollDeltaPayload(deltaX: 0, deltaY: 12)),
            .mouseButton(MouseButtonPayload(button: .right, isDown: true)),
            .textInput(try TextInputPayload(text: "héllo")),
            .hotkey(HotkeyPayload(action: .selectAll)),
            .motionPointerDelta(MotionPointerDeltaPayload(deltaX: -4, deltaY: 6, sampleRateHz: 100)),
            .audioChunk(audio),
            .acknowledgement(AcknowledgementPayload(acknowledgedSequence: 8, status: .accepted)),
            .connectionStatus(ConnectionStatusPayload(state: .authenticated)),
            .error(ErrorPayload(code: .unsafeState, retryable: false)),
            .ping(PingPayload()),
            .pong(PongPayload()),
            .mouseDoubleClick(MouseDoubleClickPayload(button: .left)),
            .appSwitcher(AppSwitcherPayload(phase: .begin))
        ]

        XCTAssertEqual(payloads.map(\.messageType), MessageType.allCases)
        for (index, payload) in payloads.enumerated() {
            let envelope = ProtocolEnvelope(
                sessionID: sessionID,
                sequence: UInt64(index + 1),
                timestampMs: Int64(index * 10),
                payload: payload
            )
            let encoded = try ProtocolCodec.encode(envelope)
            let decoded = try ProtocolCodec.decode(encoded)
            XCTAssertEqual(decoded, envelope)
            XCTAssertEqual(decoded.messageType.deliveryClass, payload.messageType.deliveryClass)
        }
    }

    func testEncodingIsCanonicalForSameEnvelope() throws {
        let payload = MessagePayload.pointerDelta(PointerDeltaPayload(deltaX: 1, deltaY: 2))
        let envelope = ProtocolEnvelope(sessionID: sessionID, sequence: 1, timestampMs: 42, payload: payload)
        XCTAssertEqual(try ProtocolCodec.encode(envelope), try ProtocolCodec.encode(envelope))
    }

    func testUnknownVersionAndTypeFailClosed() throws {
        let unknownVersion = #"{"protocolVersion":99,"sessionID":[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],"sequence":1,"timestampMs":1,"messageType":1,"payload":{"type":1,"value":{"isActive":true,"buttons":0,"modifiers":0,"heartbeatIntervalMs":250}}}"#
        XCTAssertThrowsError(try ProtocolCodec.decode(Array(unknownVersion.utf8))) { error in
            XCTAssertEqual(error as? ProtocolError, .unsupportedVersion(99))
        }

        let unknownType = #"{"protocolVersion":1,"sessionID":[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],"sequence":1,"timestampMs":1,"messageType":99,"payload":{"type":99,"value":{}}}"#
        XCTAssertThrowsError(try ProtocolCodec.decode(Array(unknownType.utf8))) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownMessageType(99))
        }
    }

    func testMalformedTruncatedAndOversizedInputAreBounded() throws {
        XCTAssertThrowsError(try ProtocolCodec.decode([])) { error in
            XCTAssertEqual(error as? ProtocolError, .emptyInput)
        }
        XCTAssertThrowsError(try ProtocolCodec.decode(Array(#"{"protocolVersion":1"#.utf8))) { error in
            XCTAssertEqual(error as? ProtocolError, .malformedInput)
        }

        let oversized = Array(repeating: UInt8(ascii: "x"), count: ProtocolLimits.maximumEnvelopeBytes + 1)
        XCTAssertThrowsError(try ProtocolCodec.decode(oversized)) { error in
            guard case .envelopeTooLarge(let actual, let limit) = error as? ProtocolError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, ProtocolLimits.maximumEnvelopeBytes + 1)
            XCTAssertEqual(limit, ProtocolLimits.maximumEnvelopeBytes)
        }
    }

    func testInvalidUTF8AndDeclaredByteArrayLimitFailBeforeFeatureUse() throws {
        let invalidUTF8 = #"{"protocolVersion":1,"sessionID":[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],"sequence":1,"timestampMs":1,"messageType":5,"payload":{"type":5,"value":{"utf8":[255]}}}"#
        XCTAssertThrowsError(try ProtocolCodec.decode(Array(invalidUTF8.utf8))) { error in
            XCTAssertEqual(error as? ProtocolError, .invalidUTF8)
        }

        let claimedBytes = Array(repeating: "1", count: ProtocolBytes.maximumCount + 1).joined(separator: ",")
        let oversizedText = "{\"protocolVersion\":1,\"sessionID\":[7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],\"sequence\":1,\"timestampMs\":1,\"messageType\":5,\"payload\":{\"type\":5,\"value\":{\"utf8\":[\(claimedBytes)]}}}"
        XCTAssertThrowsError(try ProtocolCodec.decode(Array(oversizedText.utf8))) { error in
            guard case .fieldTooLarge(let field, let actual, let limit) = error as? ProtocolError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(field, "bytes")
            XCTAssertEqual(actual, ProtocolBytes.maximumCount + 1)
            XCTAssertEqual(limit, ProtocolBytes.maximumCount)
        }
    }

    func testNumericAndPayloadBounds() throws {
        let invalid = [
            MessagePayload.heartbeat(HeartbeatPayload(isActive: true, buttons: 4)),
            MessagePayload.pointerDelta(PointerDeltaPayload(deltaX: 9_000, deltaY: 0)),
            MessagePayload.motionPointerDelta(MotionPointerDeltaPayload(deltaX: 0, deltaY: 0, sampleRateHz: 101)),
        ]
        for payload in invalid {
            let envelope = ProtocolEnvelope(sessionID: sessionID, sequence: 1, timestampMs: 1, payload: payload)
            XCTAssertThrowsError(try ProtocolCodec.encode(envelope))
        }
    }

    func testSequenceTrackerClassifiesDuplicateOutOfOrderAndGap() {
        var tracker = SequenceTracker()
        XCTAssertEqual(tracker.observe(sequence: 1), .firstAccepted)
        XCTAssertEqual(tracker.observe(sequence: 1), .duplicate)
        XCTAssertEqual(tracker.observe(sequence: 3), .gap(expected: 2, received: 3))
        XCTAssertEqual(tracker.observe(sequence: 2), .outOfOrder)
        XCTAssertEqual(tracker.observe(sequence: 4), .accepted)
        XCTAssertEqual(tracker.observe(sequence: 0), .invalid)
    }

    func testAudioChunkUsesBase64AndOptionalEndFlag() throws {
        let audio = try AudioChunkPayload(
            streamID: sessionID,
            chunkIndex: 1,
            pcm: [0, 1, 2, 3],
            samplePosition: 16,
            isLast: true
        )
        let envelope = ProtocolEnvelope(sessionID: sessionID, sequence: 1, timestampMs: 1, payload: .audioChunk(audio))
        let encoded = try ProtocolCodec.encode(envelope)
        let json = try XCTUnwrap(String(data: Data(encoded), encoding: .utf8))
        XCTAssertTrue(json.contains("\"pcm\":\"AAECAw==\""))
        XCTAssertFalse(json.contains("[0,1,2,3]"))
        XCTAssertTrue(json.contains("\"isLast\":true"))
        let decoded = try ProtocolCodec.decode(encoded)
        XCTAssertEqual(decoded, envelope)
        guard case let .audioChunk(value) = decoded.payload else {
            return XCTFail("expected audio")
        }
        XCTAssertEqual(value.samplePosition, 16)
        XCTAssertTrue(value.isLast)
        XCTAssertEqual(value.pcm.bytes, [0, 1, 2, 3])
    }

    func testIMAADPCMRoundTripStaysBounded() {
        var encoder = IMAADPCMEncoder()
        let original: [Int16] = (0..<320).map { Int16((sin(Double($0) / 8.0) * 6_000).rounded()) }
        let encoded = encoder.encode(original)
        XCTAssertLessThan(encoded.count, original.count)
        let decoded = IMAADPCM.decode(payload: encoded, sampleCount: original.count)
        XCTAssertEqual(decoded.count, original.count)
        var maxError = 0
        for (lhs, rhs) in zip(original, decoded) {
            maxError = max(maxError, abs(Int(lhs) - Int(rhs)))
        }
        XCTAssertLessThan(maxError, 3_000)
    }

    func testVoiceStreamFrameRoundTripStartDataAndEnd() throws {
        var encoder = IMAADPCMEncoder()
        let samples: [Int16] = [1_000, -2_000, 3_000, -4_000]
        let start = try VoiceStreamFrame(
            flags: .start,
            streamID: sessionID,
            sequence: 0,
            sampleCount: 0,
            payload: Data()
        )
        let data = try VoiceStreamFrame(
            flags: [],
            streamID: sessionID,
            sequence: 1,
            sampleCount: 4,
            payload: encoder.encode(samples)
        )
        let end = try VoiceStreamFrame(
            flags: .end,
            streamID: sessionID,
            sequence: 2,
            sampleCount: 0,
            payload: Data()
        )
        XCTAssertTrue(try VoiceStreamFrame.decode(start.encode()).isStart)
        let decodedData = try VoiceStreamFrame.decode(data.encode())
        XCTAssertEqual(decodedData.sampleCount, 4)
        XCTAssertEqual(IMAADPCM.decode(payload: decodedData.payload, sampleCount: 4).count, 4)
        XCTAssertTrue(try VoiceStreamFrame.decode(end.encode()).isEnd)
    }

    func testDecoderBoundedDeterministicFuzzCorpus() {
        // This is a small, reproducible property corpus rather than a source
        // of security randomness. It exercises empty, truncated, malformed,
        // and over-limit byte arrays without ever logging their contents.
        var state: UInt64 = 0x5048_4f4e_4552_454d
        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let length = Int(state % UInt64(ProtocolLimits.maximumEnvelopeBytes + 129))
            var bytes = [UInt8](repeating: 0, count: length)
            for index in bytes.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes[index] = UInt8(truncatingIfNeeded: state >> 56)
            }
            do {
                _ = try ProtocolCodec.decode(bytes)
            } catch {
                XCTAssertTrue(error is ProtocolError)
            }
        }
    }
}
