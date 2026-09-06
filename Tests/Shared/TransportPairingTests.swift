import Foundation
import CryptoKit
import XCTest
@testable import PhoneRemoteShared

final class TransportPairingTests: XCTestCase {
    func testGattContractHasOneServiceAndFourDirectionalCharacteristics() {
        XCTAssertEqual(PhoneRemoteGATT.characteristics.count, 4)
        XCTAssertEqual(PhoneRemoteGATT.allCharacteristicUUIDs.count, 4)
        XCTAssertEqual(PhoneRemoteGATT.characteristics.filter { $0.direction == .phoneToMac }.count, 2)
        XCTAssertEqual(PhoneRemoteGATT.characteristics.filter { $0.direction == .macToPhone }.count, 2)
    }

    func testFragmentationAtMinimumAndNegotiatedSizesRoundTrips() throws {
        let payload = Data((0..<255).map(UInt8.init))
        for valueLength in [20, 23, 64, 247] {
            let frames = try BLEFragmenter().fragment(
                payload: payload,
                kind: .data,
                reliable: true,
                messageID: UInt32(valueLength),
                maximumValueLength: valueLength
            )
            XCTAssertTrue(frames.allSatisfy { $0.count <= valueLength })
            let reassembler = try BLEReassembler(maximumValueLength: valueLength)
            var completed: Data?
            for encoded in frames {
                if case .complete(let data, _, _, _) = try reassembler.append(encoded) { completed = data }
            }
            XCTAssertEqual(completed, payload)
            XCTAssertEqual(reassembler.partialBytes, 0)
        }
    }

    func testFragmentationBoundAndInvalidFramesFailClosed() throws {
        let payload = Data(repeating: 0xA5, count: BLEFramingLimits.maximumEnvelopeBytes)
        let frames = try BLEFragmenter().fragment(
            payload: payload,
            kind: .data,
            reliable: false,
            messageID: 77,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        XCTAssertEqual(frames.count, BLEFramingLimits.maximumFragments)
        XCTAssertThrowsError(try BLEFragmenter().fragment(
            payload: Data(repeating: 0, count: BLEFramingLimits.maximumEnvelopeBytes + 1),
            kind: .data,
            reliable: false,
            messageID: 78,
            maximumValueLength: 20
        )) { error in XCTAssertEqual(error as? BLEFramingError, .envelopeTooLarge) }

        var invalidLength = frames[0]
        invalidLength[12] = 0xff
        invalidLength[13] = 0xff
        XCTAssertThrowsError(try BLEFrame.decode(invalidLength, maximumValueLength: 20))

        let reassembler = try BLEReassembler(maximumValueLength: 20)
        XCTAssertThrowsError(try reassembler.append(frames[1])) { error in
            XCTAssertEqual(error as? BLEFramingError, .outOfOrderFragment)
        }
        reassembler.reset()
        _ = try reassembler.append(frames[0])
        XCTAssertEqual(try reassembler.append(frames[0]), .duplicate)
    }

    func testOneTimeTokenCanonicalEncodingExpiryReplacementAndReplay() throws {
        let clock = MutablePairingClock(Date(timeIntervalSince1970: 10_000))
        let random = SequencePairingRandom(seed: 9)
        let store = OneTimePairingOfferStore(clock: clock, random: random)
        let first = try store.issue(displayName: " Test Mac ", lifetime: 120)
        let firstText = first.qrText
        let parsed = try PairingToken.decodeText(firstText)
        XCTAssertEqual(parsed, first.token)
        XCTAssertTrue(store.hasActiveOffer)

        _ = try store.issue(displayName: "Second Mac", lifetime: 2)
        XCTAssertThrowsError(try store.consume(encodedToken: firstText)) { error in
            XCTAssertEqual(error as? PairingError, .tokenNotActive)
        }
        clock.nowValue = clock.now.addingTimeInterval(2)
        let third = try store.issue(displayName: "Third Mac", lifetime: 1)
        clock.nowValue = clock.now.addingTimeInterval(1)
        XCTAssertThrowsError(try store.consume(encodedToken: third.qrText)) { error in
            XCTAssertEqual(error as? PairingError, .tokenExpired)
        }

        let fresh = try store.issue(displayName: "Fresh Mac", lifetime: 10)
        let consumed = try store.consume(encodedToken: fresh.qrText)
        XCTAssertEqual(consumed.token, fresh.token)
        XCTAssertThrowsError(try store.consume(encodedToken: fresh.qrText))
    }

    func testOneTimeOfferCanBeConsumedByPairingIDOnlyOnce() throws {
        let store = OneTimePairingOfferStore()
        let offer = try store.issue(displayName: "Mac", lifetime: 60)
        let consumed = try store.consume(pairingID: offer.token.pairingID)
        XCTAssertEqual(consumed.token, offer.token)
        XCTAssertThrowsError(try store.consume(pairingID: offer.token.pairingID)) { error in
            XCTAssertEqual(error as? PairingError, .tokenNotActive)
        }
    }

    func testAuthenticatedHandshakeEncryptsAndRejectsTamperingReplayAndWrongSecret() throws {
        let pairID = UUID()
        let secret = Data(repeating: 0x42, count: 32)
        let macEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let token = try PairingToken(
            macDisplayName: "Mac",
            macEphemeralPublicKey: macEphemeral.publicKey.rawRepresentation,
            oneTimeSecret: secret,
            pairingID: pairID,
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 220)
        )
        let macIdentity = PairingIdentity()
        let phoneIdentity = PairingIdentity()
        let handshakeClock = MutablePairingClock(Date(timeIntervalSince1970: 150))
        let client = try PairingHandshakeClient(
            mode: .oneTime(token),
            identity: phoneIdentity,
            clock: handshakeClock,
            random: SequencePairingRandom(seed: 1),
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let server = PairingHandshakeServer(
            mode: .oneTime(token),
            identity: macIdentity,
            clock: handshakeClock,
            random: SequencePairingRandom(seed: 3),
            ephemeralPrivateKey: macEphemeral
        )
        let serverHello = try server.accept(clientHelloData: client.hello)
        let clientResult = try client.accept(serverHelloData: serverHello.response)
        let serverResult = try server.accept(clientFinishData: clientResult.finish)
        XCTAssertEqual(clientResult.result.session.sessionID, serverResult.session.sessionID)
        XCTAssertEqual(clientResult.result.peerIdentityPublicKey, macIdentity.publicKey)

        let encrypted = try clientResult.result.session.encrypt(plaintext: Data("payload".utf8), messageType: 7)
        var tampered = encrypted
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(try serverResult.session.decrypt(tampered)) { error in
            XCTAssertEqual(error as? PairingError, .authenticationFailed)
        }
        XCTAssertEqual(try serverResult.session.decrypt(encrypted, expectedMessageType: 7).plaintext, Data("payload".utf8))
        XCTAssertThrowsError(try serverResult.session.decrypt(encrypted)) { error in
            XCTAssertEqual(error as? PairingError, .replayedEnvelope)
        }

        let wrongToken = try PairingToken(
            macDisplayName: token.macDisplayName,
            macEphemeralPublicKey: token.macEphemeralPublicKey,
            oneTimeSecret: Data(repeating: 0x43, count: 32),
            pairingID: token.pairingID,
            issuedAt: token.issuedAt,
            expiresAt: token.expiresAt
        )
        let wrongClient = try PairingHandshakeClient(mode: .oneTime(wrongToken), identity: phoneIdentity, ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey())
        XCTAssertThrowsError(try wrongClient.accept(serverHelloData: serverHello.response))
    }

    func testServerDeclineRoundTripsAndRejectsOtherControlMessages() throws {
        let pairingID = UUID()
        let decline = PairingServerDecline(pairingID: pairingID).encode()
        XCTAssertTrue(decline.starts(with: PairingServerDecline.magic))
        XCTAssertEqual(try PairingServerDecline.decode(decline).pairingID, pairingID)

        var wrongVersion = decline
        wrongVersion[4] = PairingToken.currentVersion &+ 1
        XCTAssertThrowsError(try PairingServerDecline.decode(wrongVersion))
        XCTAssertThrowsError(try PairingServerDecline.decode(decline.dropLast()))
        let phone = try PairingHandshakeClient(mode: .trusted(deviceID: pairingID, peerIdentityPublicKey: PairingIdentity().publicKey), identity: PairingIdentity())
        XCTAssertThrowsError(try PairingServerDecline.decode(phone.hello))
    }

    func testTrustedReconnectRejectsUnknownIdentityAndCreatesFreshSession() throws {
        let deviceID = UUID()
        let macIdentity = PairingIdentity()
        let phoneIdentity = PairingIdentity()
        let trustedModeForPhone = HandshakeMode.trusted(deviceID: deviceID, peerIdentityPublicKey: macIdentity.publicKey)
        let trustedModeForMac = HandshakeMode.trusted(deviceID: deviceID, peerIdentityPublicKey: phoneIdentity.publicKey)
        let phone = try PairingHandshakeClient(mode: trustedModeForPhone, identity: phoneIdentity, ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey())
        let mac = PairingHandshakeServer(mode: trustedModeForMac, identity: macIdentity, ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey())
        let hello = try mac.accept(clientHelloData: phone.hello)
        let clientResult = try phone.accept(serverHelloData: hello.response)
        let serverResult = try mac.accept(clientFinishData: clientResult.finish)
        XCTAssertEqual(clientResult.result.session.sessionID, serverResult.session.sessionID)

        let unknownPhone = try PairingHandshakeClient(mode: trustedModeForPhone, identity: PairingIdentity(), ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey())
        let freshMac = PairingHandshakeServer(mode: trustedModeForMac, identity: macIdentity, ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey())
        XCTAssertThrowsError(try freshMac.accept(clientHelloData: unknownPhone.hello))
    }

    func testProtocolEnvelopeEncryptsFragmentsAndDecodesEndToEnd() throws {
        let sessionID = try SessionID(bytes: Array(repeating: 0x11, count: SessionID.byteCount))
        let envelope = ProtocolEnvelope(
            sessionID: sessionID,
            sequence: 1,
            timestampMs: 42,
            payload: .pointerDelta(PointerDeltaPayload(deltaX: 17, deltaY: -9))
        )
        let plaintext = Data(try ProtocolCodec.encode(envelope))
        let key = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        let sender = try PairingSession(
            key: key,
            sessionID: Data(sessionID.bytes),
            random: SequencePairingRandom(seed: 23)
        )
        let receiver = try PairingSession(
            key: key,
            sessionID: Data(sessionID.bytes),
            random: SequencePairingRandom(seed: 77)
        )

        let encrypted = try sender.encrypt(
            plaintext: plaintext,
            messageType: MessageType.pointerDelta.rawValue
        )
        let frames = try BLEFragmenter().fragment(
            payload: encrypted,
            kind: .data,
            reliable: false,
            messageID: 901,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        let reassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var complete: Data?
        for frame in frames {
            if case let .complete(payload, _, _, _) = try reassembler.append(frame) {
                complete = payload
            }
        }
        let encryptedRoundTrip = try XCTUnwrap(complete)
        let decrypted = try receiver.decrypt(
            encryptedRoundTrip,
            expectedMessageType: MessageType.pointerDelta.rawValue
        )
        XCTAssertEqual(try ProtocolCodec.decode(Array(decrypted.plaintext)), envelope)
    }

    func testAuthenticatedPingRoundTripsToPong() throws {
        let sessionID = try SessionID(bytes: Array(repeating: 0x22, count: SessionID.byteCount))
        let key = SymmetricKey(data: Data(repeating: 0x3C, count: 32))
        let phone = try PairingSession(key: key, sessionID: Data(sessionID.bytes), random: SequencePairingRandom(seed: 3))
        let mac = try PairingSession(key: key, sessionID: Data(sessionID.bytes), random: SequencePairingRandom(seed: 9))
        let ping = ProtocolEnvelope(
            sessionID: sessionID,
            sequence: 1,
            timestampMs: 7,
            payload: .ping(PingPayload())
        )
        let frames = try BLEFragmenter().fragment(
            payload: try phone.seal(ping),
            kind: .data,
            reliable: true,
            messageID: 4,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        let reassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var complete: Data?
        for frame in frames {
            if case let .complete(payload, kind, _, _) = try reassembler.append(frame) {
                XCTAssertEqual(kind, .data)
                complete = payload
            }
        }
        let received = try mac.unwrapApplication(try XCTUnwrap(complete))
        XCTAssertEqual(received.payload, .ping(PingPayload()))
        let pong = ProtocolEnvelope(
            sessionID: sessionID,
            sequence: 1,
            timestampMs: 8,
            payload: .pong(PongPayload())
        )
        let reply = try BLEFragmenter().fragment(
            payload: try mac.seal(pong),
            kind: .data,
            reliable: true,
            messageID: 5,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        let replyReassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var replyComplete: Data?
        for frame in reply {
            if case let .complete(payload, _, _, _) = try replyReassembler.append(frame) {
                replyComplete = payload
            }
        }
        XCTAssertEqual(try phone.unwrapApplication(try XCTUnwrap(replyComplete)).payload, .pong(PongPayload()))
    }
}

private final class MutablePairingClock: PairingClock {
    var nowValue: Date
    init(_ now: Date) { nowValue = now }
    var now: Date { nowValue }
}

private final class SequencePairingRandom: PairingRandomSource {
    private var next: UInt8
    init(seed: UInt8) { next = seed }
    func bytes(count: Int) throws -> Data {
        let output = Data((0..<count).map { offset in next &+ UInt8(offset) })
        next &+= UInt8(truncatingIfNeeded: count)
        return output
    }
}
