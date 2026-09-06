import Foundation
import XCTest
@testable import PhoneRemoteShared

final class ProtocolTests: XCTestCase {
    private let sessionID = try! SessionID(bytes: Array(repeating: 7, count: SessionID.byteCount))

    /// The click count is what makes a drag widen a word selection.  A message
    /// written before the field existed has to keep decoding as a plain click.
    func testMouseButtonClickCountDefaultsToOneAndIsClamped() throws {
        let legacy = Data(#"{"button":1,"isDown":true}"#.utf8)
        let decoded = try JSONDecoder().decode(MouseButtonPayload.self, from: legacy)
        XCTAssertEqual(decoded.clickCount, 1)

        XCTAssertEqual(MouseButtonPayload(button: .left, isDown: true, clickCount: 0).clickCount, 1)
        XCTAssertEqual(MouseButtonPayload(button: .left, isDown: true, clickCount: 9).clickCount, 3)
    }

    func testRoundTripCoversEveryMVPMessageType() throws {
        let audio = try AudioChunkPayload(streamID: sessionID, chunkIndex: 3, pcm: [0, 1, 2, 3])
        let payloads: [MessagePayload] = [
            .heartbeat(HeartbeatPayload(isActive: true, buttons: 1, modifiers: 2)),
            .pointerDelta(PointerDeltaPayload(deltaX: 10, deltaY: -9)),
            .scrollDelta(ScrollDeltaPayload(deltaX: 0, deltaY: 12)),
            .mouseButton(MouseButtonPayload(button: .right, isDown: true, clickCount: 2)),
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
            .tabWalk(TabWalkPayload(phase: .begin, modifier: .command)),
            .deleteScrub(DeleteScrubPayload(phase: .delete, granularity: .word)),
            .vocabulary(try VocabularyPayload(phrases: ["Nemotron", "Ollama"])),
            .spokenText(try SpokenTextPayload(text: "héllo there"))
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

        let cancelled = try VoiceStreamFrame(
            flags: [.end, .cancel],
            streamID: sessionID,
            sequence: 3,
            sampleCount: 0,
            payload: Data()
        )
        let decodedCancel = try VoiceStreamFrame.decode(cancelled.encode())
        XCTAssertTrue(decodedCancel.isEnd)
        XCTAssertTrue(decodedCancel.isCancel)
        XCTAssertFalse(try VoiceStreamFrame.decode(end.encode()).isCancel)
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


/// The two messages that carry the word cache to the phone and the finished
/// sentence back. Both are bounded on the decoder side, because a busy window
/// and a long monologue are the two ways a caller can overrun the envelope.
final class VocabularyProtocolTests: XCTestCase {
    func testVocabularyRoundTrip() throws {
        let payload = try VocabularyPayload(phrases: ["Nemotron", "PhoneRemote", "xcodebuild"])
        let data = try JSONEncoder().encode(MessagePayload.vocabulary(payload))
        let decoded = try JSONDecoder().decode(MessagePayload.self, from: data)
        XCTAssertEqual(decoded, .vocabulary(payload))
        XCTAssertEqual(decoded.messageType, .vocabulary)
        XCTAssertEqual(MessageType.vocabulary.deliveryClass, .reliable)
    }

    func testTooManyPhrasesIsRefused() {
        let many = (0..<(VocabularyPayload.maximumPhrases + 1)).map { "word\($0)" }
        XCTAssertThrowsError(try VocabularyPayload(phrases: many))
    }

    func testOverlongPhraseIsRefused() {
        let long = String(repeating: "a", count: VocabularyPayload.maximumPhraseUTF8Bytes + 1)
        XCTAssertThrowsError(try VocabularyPayload(phrases: [long]))
    }

    func testEmptyPhraseIsRefused() {
        XCTAssertThrowsError(try VocabularyPayload(phrases: ["fine", ""]))
    }

    /// The decoder must refuse an oversized array from its declared count,
    /// before it reserves storage for the strings.
    func testDecoderRefusesAnOversizedArray() throws {
        let many = (0..<(VocabularyPayload.maximumPhrases + 20)).map { "word\($0)" }
        let json = try JSONSerialization.data(withJSONObject: ["phrases": many])
        XCTAssertThrowsError(try JSONDecoder().decode(VocabularyPayload.self, from: json))
    }

    /// One long token on screen should cost that token, not the whole push.
    func testBoundedTrimsRatherThanRefusing() {
        let long = String(repeating: "a", count: VocabularyPayload.maximumPhraseUTF8Bytes + 1)
        let kept = VocabularyPayload.bounded(["keep", long, "", "also"])
        XCTAssertEqual(kept, ["keep", "also"])
        XCTAssertNoThrow(try VocabularyPayload(phrases: kept))
    }

    func testBoundedStopsAtThePhraseCount() {
        let many = (0..<(VocabularyPayload.maximumPhrases + 50)).map { "w\($0)" }
        XCTAssertEqual(VocabularyPayload.bounded(many).count, VocabularyPayload.maximumPhrases)
    }

    func testBoundedStopsAtTheByteBudget() {
        let chunk = String(repeating: "b", count: VocabularyPayload.maximumPhraseUTF8Bytes)
        let kept = VocabularyPayload.bounded(Array(repeating: chunk, count: VocabularyPayload.maximumPhrases))
        let total = kept.reduce(0) { $0 + $1.utf8.count }
        XCTAssertLessThanOrEqual(total, VocabularyPayload.maximumTotalUTF8Bytes)
        XCTAssertLessThan(kept.count, VocabularyPayload.maximumPhrases)
    }

    func testSpokenTextRoundTripKeepsUnicode() throws {
        let payload = try SpokenTextPayload(text: "naïve café 😀")
        let data = try JSONEncoder().encode(MessagePayload.spokenText(payload))
        let decoded = try JSONDecoder().decode(MessagePayload.self, from: data)
        XCTAssertEqual(decoded, .spokenText(payload))
        XCTAssertEqual(payload.text, "naïve café 😀")
        XCTAssertEqual(MessageType.spokenText.deliveryClass, .reliable)
    }

    func testEmptySpokenTextFailsValidation() throws {
        let payload = try SpokenTextPayload(utf8: [])
        XCTAssertThrowsError(try MessagePayload.spokenText(payload).validate())
    }

    func testInvalidUTF8SpokenTextFailsValidation() throws {
        let payload = try SpokenTextPayload(utf8: [0xFF, 0xFE])
        XCTAssertThrowsError(try MessagePayload.spokenText(payload).validate())
    }
}
