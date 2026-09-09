import Foundation
import XCTest
@testable import NewMotionShared

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
        let payloads: [MessagePayload] = [
            .heartbeat(HeartbeatPayload(isActive: true, buttons: 1, modifiers: 2)),
            .pointerDelta(PointerDeltaPayload(deltaX: 10, deltaY: -9)),
            .scrollDelta(ScrollDeltaPayload(deltaX: 0, deltaY: 12)),
            .mouseButton(MouseButtonPayload(button: .right, isDown: true, clickCount: 2)),
            .textInput(try TextInputPayload(text: "héllo")),
            .hotkey(HotkeyPayload(action: .selectAll)),
            .motionPointerDelta(MotionPointerDeltaPayload(deltaX: -4, deltaY: 6, sampleRateHz: 100)),
            .acknowledgement(AcknowledgementPayload(acknowledgedSequence: 8, status: .accepted)),
            .connectionStatus(ConnectionStatusPayload(state: .authenticated)),
            .error(ErrorPayload(code: .unsafeState, retryable: false)),
            .ping(PingPayload()),
            .pong(PongPayload()),
            .mouseDoubleClick(MouseDoubleClickPayload(button: .left)),
            .tabWalk(TabWalkPayload(phase: .begin, modifier: .command)),
            .deleteScrub(DeleteScrubPayload(phase: .delete, granularity: .word)),
            .vocabulary(try VocabularyPayload(phrases: ["Ollama", "Testaflight"])),
            .spokenText(try SpokenTextPayload(text: "héllo there")),
            .keyPicker(KeyPickerPayload(phase: .highlight, cell: .save)),
            .transcriptPreview(try TranscriptPreviewPayload(text: "héllo th"))
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

    /// The commit carries the cell it fires, so an absent one has to survive
    /// the round trip as absent: it is the difference between firing nothing
    /// and firing whatever was last lit.
    func testKeyPickerRoundTripsEveryPhaseWithAndWithoutACell() throws {
        var sequence: UInt64 = 0
        for phase in KeyPickerPhase.allCases {
            for cell in [nil, HotkeyAction.cut] {
                sequence += 1
                let payload = MessagePayload.keyPicker(KeyPickerPayload(phase: phase, cell: cell))
                let envelope = ProtocolEnvelope(
                    sessionID: sessionID,
                    sequence: sequence,
                    timestampMs: 1,
                    payload: payload
                )
                let decoded = try ProtocolCodec.decode(try ProtocolCodec.encode(envelope))
                XCTAssertEqual(decoded, envelope, "\(phase) \(String(describing: cell))")
                guard case let .keyPicker(value) = decoded.payload else {
                    return XCTFail("wrong payload for \(phase)")
                }
                XCTAssertEqual(value.cell, cell, "\(phase)")
            }
        }
    }

    /// The unit flip is the one scrub phase that erases nothing, so a Mac that
    /// dropped it would light the wrong half of its card for the rest of the
    /// press.  Both units go round, because the phase and the unit are the
    /// whole message.
    func testDeleteScrubRoundTripsEveryPhaseAndUnit() throws {
        var sequence: UInt64 = 0
        for phase in DeleteScrubPhase.allCases {
            for granularity in DeleteScrubGranularity.allCases {
                sequence += 1
                let payload = MessagePayload.deleteScrub(
                    DeleteScrubPayload(phase: phase, granularity: granularity)
                )
                let envelope = ProtocolEnvelope(
                    sessionID: sessionID,
                    sequence: sequence,
                    timestampMs: 1,
                    payload: payload
                )
                let decoded = try ProtocolCodec.decode(try ProtocolCodec.encode(envelope))
                XCTAssertEqual(decoded, envelope, "\(phase) \(granularity)")
                guard case let .deleteScrub(value) = decoded.payload else {
                    return XCTFail("wrong payload for \(phase)")
                }
                XCTAssertEqual(value.phase, phase)
                XCTAssertEqual(value.granularity, granularity)
            }
        }
    }

    /// These numbers are the wire.  They were renumbered once already, when a
    /// rebase found 29 taken by `controlCenter`, and a phone and a Mac that
    /// disagree on them fire the wrong shortcut rather than fail.  Pinning them
    /// here means a reorder of either enum has to be a deliberate edit.
    func testNewWireRawValuesArePinned() {
        XCTAssertEqual(HotkeyAction.cut.rawValue, 30)
        XCTAssertEqual(HotkeyAction.save.rawValue, 31)
        XCTAssertEqual(HotkeyAction.find.rawValue, 32)
        XCTAssertEqual(HotkeyAction.previousWindow.rawValue, 33)

        XCTAssertEqual(MessageType.keyPicker.rawValue, 19)
        XCTAssertEqual(MessageType.transcriptPreview.rawValue, 20)

        XCTAssertEqual(TranscriptPreviewPhase.live.rawValue, 1)
        XCTAssertEqual(TranscriptPreviewPhase.ended.rawValue, 2)
        XCTAssertEqual(TranscriptPreviewPhase.allCases.count, 2)

        // 5 is the next free number after `end`, and a retired one is never
        // handed back out: an older Mac reads an unknown phase as a phase it
        // once knew and acts on it.
        XCTAssertEqual(DeleteScrubPhase.unitChanged.rawValue, 5)
    }

    /// Both apps draw this grid from the same table.  A reorder is a wire
    /// change, because the phone lights a cell the Mac then fires.
    func testKeyPickerGridIsPinnedAndEveryCellHasAName() {
        XCTAssertEqual(KeyPickerGrid.rows, [
            [.cancel],
            [.hotkey(.nextWindow), .hotkey(.previousWindow), .hotkey(.closeWindow), .hotkey(.newTab), .hotkey(.deleteLineBackward)],
            [.hotkey(.selectAll), .hotkey(.save), .hotkey(.find)],
            [.hotkey(.undo), .hotkey(.redo), .hotkey(.cut), .hotkey(.copy), .hotkey(.paste), .hotkey(.newItem)]
        ])

        // The way out is the first cell, so it is where a press starts and a
        // finger that never moves fires nothing.
        XCTAssertEqual(KeyPickerGrid.rows[0][0], .cancel)
        XCTAssertNil(KeyPickerCell.cancel.hotkey)

        let cells = KeyPickerGrid.rows.flatMap { $0 }
        XCTAssertEqual(cells.count, 15)
        XCTAssertEqual(Set(cells).count, cells.count, "a cell appears twice")
        for cell in cells {
            XCTAssertNotNil(KeyPickerGrid.displayName(for: cell), "\(cell)")
            XCTAssertNotNil(KeyPickerGrid.keyCap(for: cell), "\(cell)")
            XCTAssertEqual(KeyPickerGrid.cell(named: KeyPickerGrid.displayName(for: cell) ?? ""), cell)
        }
        let caps = cells.compactMap(KeyPickerGrid.keyCap(for:))
        XCTAssertEqual(Set(caps).count, caps.count, "a key cap appears twice")
        XCTAssertEqual(KeyPickerGrid.keyCap(for: .hotkey(.copy)), "C")
        XCTAssertEqual(KeyPickerGrid.keyCap(for: .hotkey(.redo)), "\u{21E7}Z")
        XCTAssertEqual(KeyPickerGrid.cell(named: "newtab"), .hotkey(.newTab))
        XCTAssertEqual(KeyPickerGrid.cell(named: "cancel"), .cancel)
        XCTAssertNil(KeyPickerGrid.cell(named: "quit"))
    }

    /// The preview is unreliable on purpose, and a live one with no words is
    /// the card saying it is listening, so unlike spoken text it must pass
    /// validation.
    func testTranscriptPreviewRoundTripsAndAcceptsAnEmptyLiveHold() throws {
        XCTAssertEqual(MessageType.transcriptPreview.deliveryClass, .unreliable)

        let cases: [(TranscriptPreviewPhase, String)] = [
            (.live, ""),
            (.live, "héllo there"),
            (.ended, "")
        ]
        for (phase, text) in cases {
            let payload = MessagePayload.transcriptPreview(
                try TranscriptPreviewPayload(phase: phase, text: text)
            )
            try payload.validate()
            let envelope = ProtocolEnvelope(
                sessionID: sessionID,
                sequence: 1,
                timestampMs: 1,
                payload: payload
            )
            let decoded = try ProtocolCodec.decode(try ProtocolCodec.encode(envelope))
            XCTAssertEqual(decoded, envelope)
            guard case let .transcriptPreview(value) = decoded.payload else {
                return XCTFail("wrong payload")
            }
            XCTAssertEqual(value.phase, phase)
            XCTAssertEqual(value.text, text)
        }
    }

    /// The end of a hold takes the card down, so words riding along with it
    /// mean the two ends disagree about which message this is.
    func testTranscriptPreviewRefusesWordsOnAnEndedHold() throws {
        let payload = MessagePayload.transcriptPreview(
            try TranscriptPreviewPayload(phase: .ended, text: "héllo there")
        )
        XCTAssertThrowsError(try payload.validate()) { error in
            XCTAssertEqual(error as? ProtocolError, .invalidField("transcript_preview_ended_words"))
        }
    }

    func testTranscriptPreviewIsBoundedAtItsOwnLimit() throws {
        XCTAssertEqual(TranscriptPreviewPayload.maximumUTF8Bytes, 128)

        let atLimit = String(repeating: "a", count: 128)
        XCTAssertNoThrow(try TranscriptPreviewPayload(text: atLimit))
        XCTAssertThrowsError(try TranscriptPreviewPayload(text: atLimit + "a")) { error in
            XCTAssertEqual(
                error as? ProtocolError,
                .fieldTooLarge("transcript_preview", actual: 129, limit: 128)
            )
        }

        // The cap counts bytes, not characters, because the wire does.
        XCTAssertThrowsError(try TranscriptPreviewPayload(text: String(repeating: "é", count: 65)))

        // The sender's bound is not the receiver's: a message that arrives
        // over the limit has to be refused on the way in as well.
        let oversized = #"{"phase":1,"text":"\#(String(repeating: "a", count: 129))"}"#
        let value = try JSONDecoder().decode(TranscriptPreviewPayload.self, from: Data(oversized.utf8))
        XCTAssertThrowsError(try MessagePayload.transcriptPreview(value).validate()) { error in
            XCTAssertEqual(
                error as? ProtocolError,
                .fieldTooLarge("transcript_preview", actual: 129, limit: 128)
            )
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
        let payload = try VocabularyPayload(phrases: ["Testaflight", "NewMotion", "xcodebuild"])
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
