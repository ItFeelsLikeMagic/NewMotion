import Foundation
import CryptoKit

public enum PairingRole: UInt8, Sendable {
    case phone = 1
    case mac = 2
}

public enum HandshakeMode: Equatable, Sendable {
    case oneTime(PairingToken)
    case trusted(deviceID: UUID, peerIdentityPublicKey: Data)

    fileprivate var pairingID: UUID {
        switch self {
        case .oneTime(let token): return token.pairingID
        case .trusted(let deviceID, _): return deviceID
        }
    }

    fileprivate var oneTimeSecret: Data? {
        if case .oneTime(let token) = self { return token.oneTimeSecret }
        return nil
    }

    fileprivate var expectedPeerIdentityPublicKey: Data? {
        if case .trusted(_, let key) = self { return key }
        return nil
    }

    fileprivate var expectedServerEphemeralPublicKey: Data? {
        if case .oneTime(let token) = self { return token.macEphemeralPublicKey }
        return nil
    }

    fileprivate var isOneTime: Bool {
        if case .oneTime = self { return true }
        return false
    }
}

public struct PairingClientHello: Equatable, Sendable {
    public static let magic = Data([0x50, 0x52, 0x43, 0x31]) // "PRC1"
    public let version: UInt8
    public let pairingID: UUID
    public let clientEphemeralPublicKey: Data
    public let clientIdentityPublicKey: Data
    public let clientNonce: Data

    public init(
        version: UInt8 = PairingToken.currentVersion,
        pairingID: UUID,
        clientEphemeralPublicKey: Data,
        clientIdentityPublicKey: Data,
        clientNonce: Data
    ) throws {
        guard version == PairingToken.currentVersion,
              clientEphemeralPublicKey.count == 32,
              clientIdentityPublicKey.count == 32,
              clientNonce.count == 16 else { throw PairingError.invalidHandshake }
        self.version = version
        self.pairingID = pairingID
        self.clientEphemeralPublicKey = clientEphemeralPublicKey
        self.clientIdentityPublicKey = clientIdentityPublicKey
        self.clientNonce = clientNonce
    }

    public func encode() -> Data {
        var output = Data()
        output.append(Self.magic)
        output.append(version)
        output.append(PairingBinary.uuidBytes(pairingID))
        output.append(clientEphemeralPublicKey)
        output.append(clientIdentityPublicKey)
        output.append(clientNonce)
        return output
    }

    public static func decode(_ data: Data) throws -> PairingClientHello {
        guard data.count == 4 + 1 + 16 + 32 + 32 + 16,
              data.prefix(4) == Self.magic else { throw PairingError.invalidHandshake }
        var cursor = 4
        guard let version = data.readUInt8(at: &cursor), version == PairingToken.currentVersion,
              let pairingData = data.readData(count: 16, at: &cursor),
              let pairingID = UUID(data: pairingData),
              let clientEphemeral = data.readData(count: 32, at: &cursor),
              let clientIdentity = data.readData(count: 32, at: &cursor),
              let nonce = data.readData(count: 16, at: &cursor),
              cursor == data.count else { throw PairingError.invalidHandshake }
        return try PairingClientHello(
            version: version,
            pairingID: pairingID,
            clientEphemeralPublicKey: clientEphemeral,
            clientIdentityPublicKey: clientIdentity,
            clientNonce: nonce
        )
    }
}

public struct PairingServerHello: Equatable, Sendable {
    public static let magic = Data([0x50, 0x52, 0x53, 0x31]) // "PRS1"
    public let version: UInt8
    public let pairingID: UUID
    public let serverEphemeralPublicKey: Data
    public let serverIdentityPublicKey: Data
    public let clientEphemeralPublicKey: Data
    public let clientIdentityPublicKey: Data
    public let serverNonce: Data
    public let authenticator: Data

    public init(
        version: UInt8 = PairingToken.currentVersion,
        pairingID: UUID,
        serverEphemeralPublicKey: Data,
        serverIdentityPublicKey: Data,
        clientEphemeralPublicKey: Data,
        clientIdentityPublicKey: Data,
        serverNonce: Data,
        authenticator: Data
    ) throws {
        guard version == PairingToken.currentVersion,
              serverEphemeralPublicKey.count == 32,
              serverIdentityPublicKey.count == 32,
              clientEphemeralPublicKey.count == 32,
              clientIdentityPublicKey.count == 32,
              serverNonce.count == 16,
              authenticator.count == 32 else { throw PairingError.invalidHandshake }
        self.version = version
        self.pairingID = pairingID
        self.serverEphemeralPublicKey = serverEphemeralPublicKey
        self.serverIdentityPublicKey = serverIdentityPublicKey
        self.clientEphemeralPublicKey = clientEphemeralPublicKey
        self.clientIdentityPublicKey = clientIdentityPublicKey
        self.serverNonce = serverNonce
        self.authenticator = authenticator
    }

    public func encode() -> Data {
        var output = encodeUnsigned()
        output.append(authenticator)
        return output
    }

    fileprivate func encodeUnsigned() -> Data {
        var output = Data()
        output.append(Self.magic)
        output.append(version)
        output.append(PairingBinary.uuidBytes(pairingID))
        output.append(serverEphemeralPublicKey)
        output.append(serverIdentityPublicKey)
        output.append(clientEphemeralPublicKey)
        output.append(clientIdentityPublicKey)
        output.append(serverNonce)
        return output
    }

    public static func decode(_ data: Data) throws -> PairingServerHello {
        let unsignedLength = 4 + 1 + 16 + 32 + 32 + 32 + 32 + 16
        guard data.count == unsignedLength + 32,
              data.prefix(4) == Self.magic else { throw PairingError.invalidHandshake }
        var cursor = 4
        guard let version = data.readUInt8(at: &cursor), version == PairingToken.currentVersion,
              let pairingData = data.readData(count: 16, at: &cursor),
              let pairingID = UUID(data: pairingData),
              let serverEphemeral = data.readData(count: 32, at: &cursor),
              let serverIdentity = data.readData(count: 32, at: &cursor),
              let clientEphemeral = data.readData(count: 32, at: &cursor),
              let clientIdentity = data.readData(count: 32, at: &cursor),
              let serverNonce = data.readData(count: 16, at: &cursor),
              let authenticator = data.readData(count: 32, at: &cursor),
              cursor == data.count else { throw PairingError.invalidHandshake }
        return try PairingServerHello(
            version: version,
            pairingID: pairingID,
            serverEphemeralPublicKey: serverEphemeral,
            serverIdentityPublicKey: serverIdentity,
            clientEphemeralPublicKey: clientEphemeral,
            clientIdentityPublicKey: clientIdentity,
            serverNonce: serverNonce,
            authenticator: authenticator
        )
    }
}

public struct PairingClientFinish: Equatable, Sendable {
    public static let magic = Data([0x50, 0x52, 0x46, 0x31]) // "PRF1"
    public let version: UInt8
    public let pairingID: UUID
    public let authenticator: Data

    public init(pairingID: UUID, authenticator: Data, version: UInt8 = PairingToken.currentVersion) throws {
        guard version == PairingToken.currentVersion, authenticator.count == 32 else {
            throw PairingError.invalidHandshake
        }
        self.version = version
        self.pairingID = pairingID
        self.authenticator = authenticator
    }

    public func encode() -> Data {
        var output = Data()
        output.append(Self.magic)
        output.append(version)
        output.append(PairingBinary.uuidBytes(pairingID))
        output.append(authenticator)
        return output
    }

    public static func decode(_ data: Data) throws -> PairingClientFinish {
        guard data.count == 4 + 1 + 16 + 32, data.prefix(4) == Self.magic else {
            throw PairingError.invalidHandshake
        }
        var cursor = 4
        guard let version = data.readUInt8(at: &cursor),
              let pairingData = data.readData(count: 16, at: &cursor),
              let pairingID = UUID(data: pairingData),
              let auth = data.readData(count: 32, at: &cursor),
              cursor == data.count else { throw PairingError.invalidHandshake }
        return try PairingClientFinish(pairingID: pairingID, authenticator: auth, version: version)
    }
}

public struct PairingHandshakeResult {
    public let session: PairingSession
    public let peerIdentityPublicKey: Data
}

public struct PairingServerHelloResult {
    public let response: Data
    public let peerIdentityPublicKey: Data
}

/// The client side is used by the iPhone. It accepts either a newly scanned
/// one-time token or a trusted-device reconnect context.
public final class PairingHandshakeClient {
    private let mode: HandshakeMode
    private let identity: PairingIdentity
    private let random: PairingRandomSource
    private let clock: PairingClock
    private let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let clientHello: PairingClientHello
    private var completed = false

    public init(
        mode: HandshakeMode,
        identity: PairingIdentity,
        clock: PairingClock = SystemPairingClock(),
        random: PairingRandomSource = SystemPairingRandomSource(),
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) throws {
        self.mode = mode
        self.identity = identity
        self.clock = clock
        self.random = random
        self.ephemeralPrivateKey = ephemeralPrivateKey
        self.clientHello = try PairingClientHello(
            pairingID: mode.pairingID,
            clientEphemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
            clientIdentityPublicKey: identity.publicKey,
            clientNonce: try random.bytes(count: 16)
        )
    }

    public var hello: Data { clientHello.encode() }

    public func accept(serverHelloData: Data) throws -> (finish: Data, result: PairingHandshakeResult) {
        guard !completed else { throw PairingError.invalidHandshake }
        guard !mode.isOneTime || !modeIsExpired else { throw PairingError.tokenExpired }
        let serverHello = try PairingServerHello.decode(serverHelloData)
        guard serverHello.pairingID == mode.pairingID,
              serverHello.clientEphemeralPublicKey == clientHello.clientEphemeralPublicKey,
              serverHello.clientIdentityPublicKey == identity.publicKey else {
            throw PairingError.authenticationFailed
        }
        if let expected = mode.expectedServerEphemeralPublicKey,
           expected != serverHello.serverEphemeralPublicKey {
            throw PairingError.authenticationFailed
        }
        if let expected = mode.expectedPeerIdentityPublicKey,
           expected != serverHello.serverIdentityPublicKey {
            throw PairingError.authenticationFailed
        }
        let serverEphemeral: Curve25519.KeyAgreement.PublicKey
        let serverIdentity: Curve25519.KeyAgreement.PublicKey
        do {
            serverEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverHello.serverEphemeralPublicKey)
            serverIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverHello.serverIdentityPublicKey)
        } catch { throw PairingError.invalidHandshake }
        let authKey = try deriveAuthKey(
            clientEphemeralPrivateKey: ephemeralPrivateKey,
            clientIdentity: identity,
            serverEphemeral: serverEphemeral,
            serverIdentity: serverIdentity,
            clientHello: clientHello,
            serverHello: serverHello,
            secret: mode.oneTimeSecret
        )
        let transcript = transcriptBytes(clientHello: clientHello, serverHello: serverHello)
        let expectedServerAuth = PairingCrypto.hmac(key: authKey, message: transcript + Data("server-auth".utf8))
        guard PairingCrypto.constantTimeEqual(expectedServerAuth, serverHello.authenticator) else {
            throw PairingError.authenticationFailed
        }
        let clientAuth = PairingCrypto.hmac(key: authKey, message: transcript + Data("client-auth".utf8))
        let finish = try PairingClientFinish(pairingID: mode.pairingID, authenticator: clientAuth).encode()
        let session = try PairingSession(
            key: deriveSessionKey(authKey: authKey, clientHello: clientHello, serverHello: serverHello),
            sessionID: deriveSessionID(transcript: transcript, clientAuth: clientAuth),
            random: random
        )
        completed = true
        return (
            finish: finish,
            result: PairingHandshakeResult(session: session, peerIdentityPublicKey: serverHello.serverIdentityPublicKey)
        )
    }

    private var modeIsExpired: Bool {
        if case .oneTime(let token) = mode { return token.isExpired(at: clock.now) }
        return false
    }

    private func deriveAuthKey(
        clientEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        clientIdentity: PairingIdentity,
        serverEphemeral: Curve25519.KeyAgreement.PublicKey,
        serverIdentity: Curve25519.KeyAgreement.PublicKey,
        clientHello: PairingClientHello,
        serverHello: PairingServerHello,
        secret: Data?
    ) throws -> SymmetricKey {
        let ephemeralSecret = try clientEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: serverEphemeral)
        let identitySecret = try clientIdentity.privateKey.sharedSecretFromKeyAgreement(with: serverIdentity)
        var material = Data()
        material.append(ephemeralSecret.withUnsafeBytes { Data($0) })
        material.append(identitySecret.withUnsafeBytes { Data($0) })
        if let secret { material.append(secret) }
        return PairingCrypto.deriveKey(
            material: material,
            salt: PairingBinary.uuidBytes(mode.pairingID),
            info: Data("PhoneRemote/handshake-auth/v1/phone-to-mac".utf8)
        )
    }
}

/// The server side is used by the Mac. For a one-time pairing the ephemeral
/// private key must be the one retained by OneTimePairingOfferStore. For a
/// reconnect a fresh ephemeral key is generated by the caller.
public final class PairingHandshakeServer {
    private let mode: HandshakeMode
    private let identity: PairingIdentity
    private let random: PairingRandomSource
    private let clock: PairingClock
    private let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private var clientHello: PairingClientHello?
    private var serverHello: PairingServerHello?
    private var authKey: SymmetricKey?
    private var transcript: Data?
    private var completed = false

    public init(
        mode: HandshakeMode,
        identity: PairingIdentity,
        clock: PairingClock = SystemPairingClock(),
        random: PairingRandomSource = SystemPairingRandomSource(),
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        self.mode = mode
        self.identity = identity
        self.clock = clock
        self.random = random
        self.ephemeralPrivateKey = ephemeralPrivateKey
    }

    public func accept(clientHelloData: Data) throws -> PairingServerHelloResult {
        guard !completed, clientHello == nil else { throw PairingError.invalidHandshake }
        guard !mode.isOneTime || !modeIsExpired else { throw PairingError.tokenExpired }
        let hello = try PairingClientHello.decode(clientHelloData)
        guard hello.pairingID == mode.pairingID else { throw PairingError.authenticationFailed }
        if let expected = mode.expectedPeerIdentityPublicKey, expected != hello.clientIdentityPublicKey {
            throw PairingError.authenticationFailed
        }
        let clientEphemeral: Curve25519.KeyAgreement.PublicKey
        let clientIdentity: Curve25519.KeyAgreement.PublicKey
        do {
            clientEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.clientEphemeralPublicKey)
            clientIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.clientIdentityPublicKey)
        } catch { throw PairingError.invalidHandshake }
        let serverHelloWithoutAuth = try PairingServerHello(
            pairingID: mode.pairingID,
            serverEphemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
            serverIdentityPublicKey: identity.publicKey,
            clientEphemeralPublicKey: hello.clientEphemeralPublicKey,
            clientIdentityPublicKey: hello.clientIdentityPublicKey,
            serverNonce: try random.bytes(count: 16),
            authenticator: Data(repeating: 0, count: 32)
        )
        let authKey = try deriveAuthKey(
            clientEphemeralPrivateKey: nil,
            clientIdentity: nil,
            serverEphemeral: nil,
            serverIdentityPublic: nil,
            clientHello: hello,
            serverHello: serverHelloWithoutAuth,
            secret: mode.oneTimeSecret,
            serverEphemeralPrivateKey: ephemeralPrivateKey,
            serverIdentity: identity,
            clientEphemeralPublicKey: clientEphemeral,
            clientIdentityPublicKey: clientIdentity
        )
        let transcript = transcriptBytes(clientHello: hello, serverHello: serverHelloWithoutAuth)
        let authenticator = PairingCrypto.hmac(key: authKey, message: transcript + Data("server-auth".utf8))
        let responseHello = try PairingServerHello(
            pairingID: serverHelloWithoutAuth.pairingID,
            serverEphemeralPublicKey: serverHelloWithoutAuth.serverEphemeralPublicKey,
            serverIdentityPublicKey: serverHelloWithoutAuth.serverIdentityPublicKey,
            clientEphemeralPublicKey: serverHelloWithoutAuth.clientEphemeralPublicKey,
            clientIdentityPublicKey: serverHelloWithoutAuth.clientIdentityPublicKey,
            serverNonce: serverHelloWithoutAuth.serverNonce,
            authenticator: authenticator
        )
        self.clientHello = hello
        self.serverHello = responseHello
        self.authKey = authKey
        self.transcript = transcript
        return PairingServerHelloResult(response: responseHello.encode(), peerIdentityPublicKey: hello.clientIdentityPublicKey)
    }

    public func accept(clientFinishData: Data) throws -> PairingHandshakeResult {
        guard !completed,
              let clientHello,
              let serverHello,
              let authKey,
              let transcript else { throw PairingError.invalidHandshake }
        let finish = try PairingClientFinish.decode(clientFinishData)
        guard finish.pairingID == mode.pairingID else { throw PairingError.authenticationFailed }
        let expected = PairingCrypto.hmac(key: authKey, message: transcript + Data("client-auth".utf8))
        guard PairingCrypto.constantTimeEqual(expected, finish.authenticator) else {
            throw PairingError.authenticationFailed
        }
        let session = try PairingSession(
            key: deriveSessionKey(authKey: authKey, clientHello: clientHello, serverHello: serverHello),
            sessionID: deriveSessionID(transcript: transcript, clientAuth: finish.authenticator),
            random: random
        )
        completed = true
        return PairingHandshakeResult(session: session, peerIdentityPublicKey: clientHello.clientIdentityPublicKey)
    }

    private var modeIsExpired: Bool {
        if case .oneTime(let token) = mode { return token.isExpired(at: clock.now) }
        return false
    }

    private func deriveAuthKey(
        clientEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?,
        clientIdentity: PairingIdentity?,
        serverEphemeral: Curve25519.KeyAgreement.PublicKey?,
        serverIdentityPublic: Curve25519.KeyAgreement.PublicKey?,
        clientHello: PairingClientHello,
        serverHello: PairingServerHello,
        secret: Data?,
        serverEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey? = nil,
        serverIdentity: PairingIdentity? = nil,
        clientEphemeralPublicKey: Curve25519.KeyAgreement.PublicKey? = nil,
        clientIdentityPublicKey: Curve25519.KeyAgreement.PublicKey? = nil
    ) throws -> SymmetricKey {
        let ephemeralSecret: SharedSecret
        let identitySecret: SharedSecret
        if let clientEphemeralPrivateKey, let serverEphemeral {
            ephemeralSecret = try clientEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: serverEphemeral)
        } else if let serverEphemeralPrivateKey, let clientEphemeralPublicKey {
            ephemeralSecret = try serverEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: clientEphemeralPublicKey)
        } else { throw PairingError.invalidHandshake }
        if let clientIdentity, let serverIdentityPublic {
            identitySecret = try clientIdentity.privateKey.sharedSecretFromKeyAgreement(with: serverIdentityPublic)
        } else if let serverIdentity, let clientIdentityPublicKey {
            identitySecret = try serverIdentity.privateKey.sharedSecretFromKeyAgreement(with: clientIdentityPublicKey)
        } else { throw PairingError.invalidHandshake }
        var material = Data()
        material.append(ephemeralSecret.withUnsafeBytes { Data($0) })
        material.append(identitySecret.withUnsafeBytes { Data($0) })
        if let secret { material.append(secret) }
        return PairingCrypto.deriveKey(
            material: material,
            salt: PairingBinary.uuidBytes(mode.pairingID),
            info: Data("PhoneRemote/handshake-auth/v1/phone-to-mac".utf8)
        )
    }
}

/// An authenticated session protects already-serialized protocol envelopes.
/// It enforces a fresh session ID and a strictly increasing receive sequence;
/// gaps are allowed so unreliable messages can be dropped by the transport.
/// Send and receive counters are guarded by `lock`, so one session can encrypt
/// from the voice queue while the main thread encrypts application messages.
public final class PairingSession: @unchecked Sendable {
    public static let currentVersion: UInt8 = 1
    private static let magic = Data([0x50, 0x52, 0x45, 0x31]) // "PRE1"
    public static let maxPlaintextBytes = 8_192

    public let sessionID: Data
    private let key: SymmetricKey
    private let random: PairingRandomSource
    private let lock = NSLock()
    private var nextSendSequence: UInt64 = 0
    private var highestReceivedSequence: UInt64?
    /// One bit per recently accepted sequence, bit 0 being the highest one seen.
    /// A strict climb was wrong for the unreliable streams: the cursor path
    /// encrypts inline on the main actor while the voice path takes its number
    /// on its own queue and sends a moment later, so the two can swap places on
    /// the wire.  Rejecting anything that is not the new highest threw the
    /// loser of that race away.  Sixty-four slots is about a second of cursor
    /// traffic, far more reordering than the link can produce.
    private var receivedWindow: UInt64 = 0
    private static let replayWindowSize: UInt64 = 64

    public init(key: SymmetricKey, sessionID: Data, random: PairingRandomSource = SystemPairingRandomSource()) throws {
        guard sessionID.count == 16 else { throw PairingError.invalidHandshake }
        self.key = key
        self.sessionID = sessionID
        self.random = random
    }

    public func encrypt(plaintext: Data, messageType: UInt8) throws -> Data {
        guard plaintext.count <= Self.maxPlaintextBytes else { throw PairingError.messageTooLarge }
        lock.lock()
        defer { lock.unlock() }
        guard nextSendSequence < UInt64.max else { throw PairingError.sequenceRollback }
        let sequence = nextSendSequence
        nextSendSequence += 1
        let nonceData = try random.bytes(count: 12)
        let nonce: ChaChaPoly.Nonce
        do { nonce = try ChaChaPoly.Nonce(data: nonceData) }
        catch { throw PairingError.nonceGenerationFailed }
        let header = envelopeHeader(sequence: sequence, messageType: messageType, nonce: nonceData, ciphertextLength: plaintext.count)
        let sealed: ChaChaPoly.SealedBox
        do { sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: header) }
        catch { throw PairingError.authenticationFailed }
        var output = header
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    public func decrypt(_ envelope: Data, expectedMessageType: UInt8? = nil) throws -> (messageType: UInt8, plaintext: Data) {
        let minimum = 4 + 1 + 16 + 8 + 1 + 12 + 2 + 16
        guard envelope.count >= minimum,
              envelope.prefix(4) == Self.magic else { throw PairingError.invalidHandshake }
        var cursor = 4
        guard let version = envelope.readUInt8(at: &cursor), version == Self.currentVersion,
              let sessionID = envelope.readData(count: 16, at: &cursor), sessionID == self.sessionID,
              let sequence = envelope.readUInt64(at: &cursor),
              let messageType = envelope.readUInt8(at: &cursor),
              let nonceData = envelope.readData(count: 12, at: &cursor),
              let ciphertextLength = envelope.readUInt16(at: &cursor),
              ciphertextLength <= Self.maxPlaintextBytes,
              cursor + Int(ciphertextLength) + 16 == envelope.count else {
            throw PairingError.invalidHandshake
        }
        if let expectedMessageType, expectedMessageType != messageType {
            throw PairingError.invalidHandshake
        }
        lock.lock()
        let freshness = replayCheck(sequence)
        lock.unlock()
        if let error = freshness { throw error }
        let header = envelope.prefix(cursor)
        let ciphertext = envelope.subdata(in: cursor..<(cursor + Int(ciphertextLength)))
        let tag = envelope.subdata(in: (cursor + Int(ciphertextLength))..<envelope.count)
        let nonce: ChaChaPoly.Nonce
        do { nonce = try ChaChaPoly.Nonce(data: nonceData) }
        catch { throw PairingError.invalidHandshake }
        let box: ChaChaPoly.SealedBox
        do { box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) }
        catch { throw PairingError.invalidHandshake }
        let plaintext: Data
        do { plaintext = try ChaChaPoly.open(box, using: key, authenticating: header) }
        catch { throw PairingError.authenticationFailed }
        // The window only moves once the tag has verified, so a forged or
        // corrupt frame can never retire a sequence the real peer still owes.
        lock.lock()
        defer { lock.unlock() }
        if let error = replayCheck(sequence) { throw error }
        recordReceived(sequence)
        return (messageType, plaintext)
    }

    /// `nil` when the sequence may be accepted.  Caller holds `lock`.
    private func replayCheck(_ sequence: UInt64) -> PairingError? {
        guard let highestReceivedSequence else { return nil }
        if sequence > highestReceivedSequence { return nil }
        let distance = highestReceivedSequence - sequence
        guard distance < Self.replayWindowSize else { return .sequenceRollback }
        return receivedWindow & (1 << distance) == 0 ? nil : .replayedEnvelope
    }

    /// Caller holds `lock`.
    private func recordReceived(_ sequence: UInt64) {
        guard let highest = highestReceivedSequence else {
            highestReceivedSequence = sequence
            receivedWindow = 1
            return
        }
        if sequence > highest {
            let shift = sequence - highest
            receivedWindow = shift >= Self.replayWindowSize ? 1 : (receivedWindow << shift) | 1
            highestReceivedSequence = sequence
            return
        }
        let distance = highest - sequence
        if distance < Self.replayWindowSize { receivedWindow |= (1 << distance) }
    }

    public func wrapApplication(
        _ envelope: ProtocolEnvelope,
        messageID: UInt32,
        maximumValueLength: Int,
        reliable: Bool? = nil
    ) throws -> [Data] {
        let plaintext = Data(try ProtocolCodec.encode(envelope))
        let encrypted = try encrypt(plaintext: plaintext, messageType: envelope.messageType.rawValue)
        return try BLEFragmenter().fragment(
            payload: encrypted,
            kind: .data,
            reliable: reliable ?? (envelope.messageType.deliveryClass == .reliable),
            messageID: messageID,
            maximumValueLength: max(BLEFramingLimits.minimumValueLength, maximumValueLength)
        )
    }

    public func wrapBinary(
        _ plaintext: Data,
        messageType: UInt8,
        messageID: UInt32,
        maximumValueLength: Int,
        reliable: Bool
    ) throws -> [Data] {
        let encrypted = try encrypt(plaintext: plaintext, messageType: messageType)
        return try BLEFragmenter().fragment(
            payload: encrypted,
            kind: .data,
            reliable: reliable,
            messageID: messageID,
            maximumValueLength: max(BLEFramingLimits.minimumValueLength, maximumValueLength)
        )
    }

    public func unwrapApplication(_ payload: Data) throws -> ProtocolEnvelope {
        try ProtocolCodec.decode(Array(decrypt(payload).plaintext))
    }

    private func envelopeHeader(sequence: UInt64, messageType: UInt8, nonce: Data, ciphertextLength: Int) -> Data {
        var output = Data()
        output.append(Self.magic)
        output.append(Self.currentVersion)
        output.append(sessionID)
        output.append(contentsOf: PairingBinary.uInt64Bytes(sequence))
        output.append(messageType)
        output.append(nonce)
        output.append(contentsOf: [UInt8((ciphertextLength >> 8) & 0xff), UInt8(ciphertextLength & 0xff)])
        return output
    }
}

private func transcriptBytes(clientHello: PairingClientHello, serverHello: PairingServerHello) -> Data {
    var output = Data("PhoneRemote/pairing-transcript/v1".utf8)
    output.append(PairingBinary.uuidBytes(clientHello.pairingID))
    output.append(clientHello.encode())
    output.append(serverHello.encodeUnsigned())
    return output
}

private func deriveSessionKey(authKey: SymmetricKey, clientHello: PairingClientHello, serverHello: PairingServerHello) -> SymmetricKey {
    var salt = Data()
    salt.append(clientHello.clientNonce)
    salt.append(serverHello.serverNonce)
    var info = Data("PhoneRemote/session-key/v1/phone-to-mac".utf8)
    info.append(PairingBinary.uuidBytes(clientHello.pairingID))
    return PairingCrypto.deriveKey(material: authKey.dataRepresentation, salt: salt, info: info)
}

private func deriveSessionID(transcript: Data, clientAuth: Data) -> Data {
    var data = transcript
    data.append(clientAuth)
    return Data(SHA256.hash(data: data).prefix(16))
}

private enum PairingCrypto {
    static func deriveKey(material: Data, salt: Data, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    static func hmac(key: SymmetricKey, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}

private enum PairingBinary {
    static func uuidBytes(_ uuid: UUID) -> Data {
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    static func uInt64Bytes(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xff), UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
    }
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}

private extension Data {
    func readUInt8(at cursor: inout Int) -> UInt8? {
        guard cursor < count else { return nil }
        defer { cursor += 1 }
        return self[cursor]
    }

    func readUInt16(at cursor: inout Int) -> UInt16? {
        guard cursor + 2 <= count else { return nil }
        let value = (UInt16(self[cursor]) << 8) | UInt16(self[cursor + 1])
        cursor += 2
        return value
    }

    func readUInt64(at cursor: inout Int) -> UInt64? {
        guard cursor + 8 <= count else { return nil }
        var result: UInt64 = 0
        for byte in self[cursor..<(cursor + 8)] { result = (result << 8) | UInt64(byte) }
        cursor += 8
        return result
    }

    func readData(count: Int, at cursor: inout Int) -> Data? {
        guard count >= 0, cursor + count <= self.count else { return nil }
        defer { cursor += count }
        return subdata(in: cursor..<(cursor + count))
    }
}

private extension UUID {
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        self = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }
}
