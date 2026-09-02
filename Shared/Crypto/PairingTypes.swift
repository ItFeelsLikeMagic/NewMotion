import Foundation
import CryptoKit
import Security

/// Errors intentionally do not include token, key, ciphertext, or plaintext
/// material. Callers can map these cases to a user-safe status message.
public enum PairingError: Error, Equatable, Sendable {
    case malformedToken
    case unsupportedVersion(UInt8)
    case tokenTooLarge
    case invalidDisplayName
    case invalidKeyMaterial
    case tokenExpired
    case tokenNotActive
    case tokenAlreadyUsed
    case invalidPairingIdentifier
    case invalidHandshake
    case authenticationFailed
    case replayedEnvelope
    case sequenceRollback
    case messageTooLarge
    case nonceGenerationFailed
    case keychainFailure(OSStatus)
}

public protocol PairingClock {
    var now: Date { get }
}

public struct SystemPairingClock: PairingClock {
    public init() {}
    public var now: Date { Date() }
}

public protocol PairingRandomSource {
    func bytes(count: Int) throws -> Data
}

public struct SystemPairingRandomSource: PairingRandomSource {
    public init() {}

    public func bytes(count: Int) throws -> Data {
        guard count >= 0 else { throw PairingError.nonceGenerationFailed }
        if count == 0 { return Data() }
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PairingError.nonceGenerationFailed }
        return data
    }
}

/// The QR offer is deliberately a small canonical binary record. Fixed-size
/// key/secret fields and a length-prefixed display name make decoding bounded
/// before any allocation based on untrusted input.
public struct PairingToken: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1
    public static let magic = Data([0x50, 0x52, 0x51, 0x52]) // "PRQR"
    public static let maxDisplayNameUTF8Bytes = 48
    public static let maxEncodedBytes = 150
    public static let maxTextCharacters = 256
    public static let maximumLifetime: TimeInterval = 120

    public let version: UInt8
    public let macDisplayName: String
    public let macEphemeralPublicKey: Data
    public let oneTimeSecret: Data
    public let pairingID: UUID
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        version: UInt8 = PairingToken.currentVersion,
        macDisplayName: String,
        macEphemeralPublicKey: Data,
        oneTimeSecret: Data,
        pairingID: UUID,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        guard version == Self.currentVersion else { throw PairingError.unsupportedVersion(version) }
        let safeName = try Self.validatedDisplayName(macDisplayName)
        guard macEphemeralPublicKey.count == 32, oneTimeSecret.count == 32 else {
            throw PairingError.invalidKeyMaterial
        }
        guard macEphemeralPublicKey.contains(where: { $0 != 0 }),
              oneTimeSecret.contains(where: { $0 != 0 }) else {
            throw PairingError.invalidKeyMaterial
        }
        do {
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macEphemeralPublicKey)
        } catch {
            throw PairingError.invalidKeyMaterial
        }
        guard expiresAt >= issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= Self.maximumLifetime,
              issuedAt.timeIntervalSince1970 >= 0 else {
            throw PairingError.malformedToken
        }
        self.version = version
        self.macDisplayName = safeName
        self.macEphemeralPublicKey = macEphemeralPublicKey
        self.oneTimeSecret = oneTimeSecret
        self.pairingID = pairingID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func encodeBinary() throws -> Data {
        let name = Data(macDisplayName.utf8)
        guard name.count <= Self.maxDisplayNameUTF8Bytes else { throw PairingError.invalidDisplayName }
        var output = Data()
        output.append(Self.magic)
        output.append(version)
        output.append(UInt8(name.count))
        output.append(name)
        output.append(macEphemeralPublicKey)
        output.append(oneTimeSecret)
        output.append(Self.uuidBytes(pairingID))
        output.append(contentsOf: Self.uInt64Bytes(Self.milliseconds(issuedAt)))
        output.append(contentsOf: Self.uInt64Bytes(Self.milliseconds(expiresAt)))
        guard output.count <= Self.maxEncodedBytes else { throw PairingError.tokenTooLarge }
        return output
    }

    /// The text representation is intended for QR encoding. Base64URL is
    /// canonical (no padding, no whitespace) and has a fixed `prqr1.` tag.
    public func encodeText() throws -> String {
        let body = try encodeBinary().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "prqr1." + body
    }

    public func isExpired(at date: Date) -> Bool { date >= expiresAt }

    public static func decodeText(_ text: String) throws -> PairingToken {
        guard text.utf8.count <= Self.maxTextCharacters,
              text.hasPrefix("prqr1.") else { throw PairingError.malformedToken }
        let encoded = String(text.dropFirst(6))
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
                  (scalar.value >= 0x61 && scalar.value <= 0x7A) ||
                  (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                  scalar.value == 0x2D || scalar.value == 0x5F
              }) else { throw PairingError.malformedToken }
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding) else {
            throw PairingError.malformedToken
        }
        guard bytes.count <= Self.maxEncodedBytes else { throw PairingError.tokenTooLarge }
        let token = try decodeBinary(bytes)
        // Reject alternate encodings and non-canonical trailing/padding forms.
        guard try token.encodeText() == text else { throw PairingError.malformedToken }
        return token
    }

    public static func decodeBinary(_ bytes: Data) throws -> PairingToken {
        guard bytes.count <= Self.maxEncodedBytes,
              bytes.count >= 4 + 1 + 1 + 32 + 32 + 16 + 8 + 8,
              bytes.prefix(4) == Self.magic else { throw PairingError.malformedToken }
        var cursor = 4
        guard let version = bytes.readUInt8(at: &cursor) else { throw PairingError.malformedToken }
        guard version == Self.currentVersion else { throw PairingError.unsupportedVersion(version) }
        guard let nameLength = bytes.readUInt8(at: &cursor), nameLength <= Self.maxDisplayNameUTF8Bytes,
              cursor + Int(nameLength) + 32 + 32 + 16 + 8 + 8 == bytes.count else {
            throw PairingError.malformedToken
        }
        let nameData = bytes.subdata(in: cursor..<(cursor + Int(nameLength)))
        cursor += Int(nameLength)
        guard let name = String(data: nameData, encoding: .utf8) else { throw PairingError.invalidDisplayName }
        let safeName = try validatedDisplayName(name)
        guard let publicKey = bytes.readData(count: 32, at: &cursor),
              let secret = bytes.readData(count: 32, at: &cursor),
              let pairingBytes = bytes.readData(count: 16, at: &cursor),
              let pairingID = UUID(data: pairingBytes),
              let issuedMillis = bytes.readUInt64(at: &cursor),
              let expiryMillis = bytes.readUInt64(at: &cursor),
              cursor == bytes.count else { throw PairingError.malformedToken }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(issuedMillis) / 1000)
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiryMillis) / 1000)
        return try PairingToken(
            version: version,
            macDisplayName: safeName,
            macEphemeralPublicKey: publicKey,
            oneTimeSecret: secret,
            pairingID: pairingID,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    private static func validatedDisplayName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Data(trimmed.utf8).count <= Self.maxDisplayNameUTF8Bytes else {
            throw PairingError.invalidDisplayName
        }
        guard !trimmed.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
        }) else {
            throw PairingError.invalidDisplayName
        }
        return trimmed
    }

    private static func milliseconds(_ date: Date) -> UInt64 {
        UInt64(max(0, Int64((date.timeIntervalSince1970 * 1000).rounded(.down))))
    }

    private static func uInt64Bytes(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xff), UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
    }

    private static func uuidBytes(_ uuid: UUID) -> Data {
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
}

public struct PairingOffer {
    public let token: PairingToken
    public let macEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey

    public init(token: PairingToken, macEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.token = token
        self.macEphemeralPrivateKey = macEphemeralPrivateKey
    }

    public var qrText: String { (try? token.encodeText()) ?? "" }
}

/// Owns the one-active-token state on the Mac. Consumption is atomic under a
/// lock so two phones racing to scan a QR can never both establish a pairing.
public final class OneTimePairingOfferStore {
    private let clock: PairingClock
    private let random: PairingRandomSource
    private let keyFactory: () throws -> Curve25519.KeyAgreement.PrivateKey
    private let lock = NSLock()
    private var active: PairingOffer?
    private var usedPairingIDs = Set<UUID>()

    public init(
        clock: PairingClock = SystemPairingClock(),
        random: PairingRandomSource = SystemPairingRandomSource(),
        keyFactory: @escaping () throws -> Curve25519.KeyAgreement.PrivateKey = {
            Curve25519.KeyAgreement.PrivateKey()
        }
    ) {
        self.clock = clock
        self.random = random
        self.keyFactory = keyFactory
    }

    @discardableResult
    public func issue(displayName: String, lifetime: TimeInterval = PairingToken.maximumLifetime) throws -> PairingOffer {
        let now = clock.now
        let boundedLifetime = min(max(1, lifetime), PairingToken.maximumLifetime)
        let privateKey = try keyFactory()
        let secret = try random.bytes(count: 32)
        let pairingBytes = try random.bytes(count: 16)
        guard let pairingID = UUID(data: pairingBytes) else { throw PairingError.malformedToken }
        let token = try PairingToken(
            macDisplayName: displayName,
            macEphemeralPublicKey: privateKey.publicKey.rawRepresentation,
            oneTimeSecret: secret,
            pairingID: pairingID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(boundedLifetime)
        )
        let offer = PairingOffer(token: token, macEphemeralPrivateKey: privateKey)
        lock.lock()
        defer { lock.unlock() }
        active = offer
        return offer
    }

    public func cancel() {
        lock.lock()
        active = nil
        lock.unlock()
    }

    public func consume(encodedToken: String) throws -> PairingOffer {
        let parsed = try PairingToken.decodeText(encodedToken)
        lock.lock()
        defer { lock.unlock() }
        guard let offer = active else { throw PairingError.tokenNotActive }
        guard offer.token == parsed else { throw PairingError.tokenNotActive }
        guard !usedPairingIDs.contains(parsed.pairingID) else {
            active = nil
            throw PairingError.tokenAlreadyUsed
        }
        guard !parsed.isExpired(at: clock.now) else {
            active = nil
            throw PairingError.tokenExpired
        }
        usedPairingIDs.insert(parsed.pairingID)
        active = nil
        return offer
    }

    /// Consumes the active offer after the peer has presented its validated
    /// pairing identifier over the authenticated transport. The full QR token
    /// never needs to cross BLE, and the same atomic single-use/expiry rules
    /// apply as `consume(encodedToken:)`.
    public func consume(pairingID: UUID) throws -> PairingOffer {
        lock.lock()
        defer { lock.unlock() }
        guard let offer = active else { throw PairingError.tokenNotActive }
        guard offer.token.pairingID == pairingID else { throw PairingError.tokenNotActive }
        guard !usedPairingIDs.contains(pairingID) else {
            active = nil
            throw PairingError.tokenAlreadyUsed
        }
        guard !offer.token.isExpired(at: clock.now) else {
            active = nil
            throw PairingError.tokenExpired
        }
        usedPairingIDs.insert(pairingID)
        active = nil
        return offer
    }

    public var hasActiveOffer: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { return false }
        return !active.token.isExpired(at: clock.now)
    }
}

/// A long-term X25519 identity is stored in Keychain and is used only to
/// authenticate future fresh ephemeral handshakes. The private key bytes are
/// never intended for logging or QR display.
public struct PairingIdentity {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(rawPrivateKey: Data) throws {
        do {
            self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
        } catch {
            throw PairingError.invalidKeyMaterial
        }
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var rawPrivateKey: Data { privateKey.rawRepresentation }
}

public struct TrustedDeviceRecord: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let displayName: String
    public let peerIdentityPublicKey: Data
    public let localIdentityPrivateKey: Data
    public let pairedAt: Date

    public init(
        deviceID: UUID,
        displayName: String,
        peerIdentityPublicKey: Data,
        localIdentityPrivateKey: Data,
        pairedAt: Date = Date()
    ) throws {
        guard peerIdentityPublicKey.count == 32, localIdentityPrivateKey.count == 32 else {
            throw PairingError.invalidKeyMaterial
        }
        guard !displayName.isEmpty, !displayName.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
        }) else {
            throw PairingError.invalidDisplayName
        }
        self.deviceID = deviceID
        self.displayName = displayName
        self.peerIdentityPublicKey = peerIdentityPublicKey
        self.localIdentityPrivateKey = localIdentityPrivateKey
        self.pairedAt = pairedAt
    }
}

public protocol TrustedDeviceStore {
    func save(_ record: TrustedDeviceRecord) throws
    func record(for deviceID: UUID) throws -> TrustedDeviceRecord?
    func allRecords() throws -> [TrustedDeviceRecord]
    func delete(deviceID: UUID) throws
    func deleteAll() throws
}

public final class InMemoryTrustedDeviceStore: TrustedDeviceStore {
    private let lock = NSLock()
    private var records: [UUID: TrustedDeviceRecord] = [:]

    public init() {}

    public func save(_ record: TrustedDeviceRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[record.deviceID] = record
    }

    public func record(for deviceID: UUID) throws -> TrustedDeviceRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[deviceID]
    }

    public func allRecords() throws -> [TrustedDeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func delete(deviceID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey: deviceID)
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }
}

/// A device-only Keychain record. The service is injected so app targets can
/// provide their bundle-specific namespace without putting identifiers in the
/// shared implementation.
public final class KeychainTrustedDeviceStore: TrustedDeviceStore {
    private static let account = "trusted-devices"
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [TrustedDeviceRecord]?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ record: TrustedDeviceRecord) throws {
        var records = try allRecords()
        records.removeAll { $0.deviceID == record.deviceID }
        records.append(record)
        try writeAll(records.sorted { $0.pairedAt < $1.pairedAt })
    }

    public func record(for deviceID: UUID) throws -> TrustedDeviceRecord? {
        try allRecords().first { $0.deviceID == deviceID }
    }

    public func allRecords() throws -> [TrustedDeviceRecord] {
        if let cache { return cache }
        if let stored = try loadBundle() {
            cache = stored
            return stored
        }
        let legacy = try loadLegacyRecords()
        if !legacy.isEmpty {
            try writeAll(legacy)
            try deleteLegacyRecords()
        }
        cache = legacy
        return legacy
    }

    public func delete(deviceID: UUID) throws {
        try writeAll(try allRecords().filter { $0.deviceID != deviceID })
    }

    public func deleteAll() throws {
        cache = []
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingError.keychainFailure(status)
        }
    }

    private func loadBundle() throws -> [TrustedDeviceRecord]? {
        var query = baseQuery(account: Self.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingError.keychainFailure(status)
        }
        do { return try decoder.decode([TrustedDeviceRecord].self, from: data) }
        catch { throw PairingError.malformedToken }
    }

    private func writeAll(_ records: [TrustedDeviceRecord]) throws {
        cache = records
        if records.isEmpty {
            let status = SecItemDelete(baseQuery(account: Self.account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PairingError.keychainFailure(status)
            }
            return
        }
        let data = try encoder.encode(records)
        var query = baseQuery(account: Self.account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: Self.account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            _ = SecItemDelete(baseQuery(account: Self.account) as CFDictionary)
            let retry = SecItemAdd(query as CFDictionary, nil)
            guard retry == errSecSuccess else { throw PairingError.keychainFailure(retry) }
        } else if addStatus != errSecSuccess {
            _ = SecItemDelete(baseQuery(account: Self.account) as CFDictionary)
            let retry = SecItemAdd(query as CFDictionary, nil)
            guard retry == errSecSuccess else { throw PairingError.keychainFailure(retry) }
        }
    }

    private func loadLegacyRecords() throws -> [TrustedDeviceRecord] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let values = result as? [[String: Any]] else {
            throw PairingError.keychainFailure(status)
        }
        let deviceIDs = values.compactMap { attributes -> UUID? in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  account != Self.account else { return nil }
            return UUID(uuidString: account)
        }
        return try deviceIDs.compactMap { deviceID in try loadLegacyRecord(deviceID) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    private func loadLegacyRecord(_ deviceID: UUID) throws -> TrustedDeviceRecord? {
        var query = baseQuery(account: deviceID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingError.keychainFailure(status)
        }
        do { return try decoder.decode(TrustedDeviceRecord.self, from: data) }
        catch { throw PairingError.malformedToken }
    }

    private func deleteLegacyRecords() throws {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let values = result as? [[String: Any]] else {
            throw PairingError.keychainFailure(status)
        }
        for attributes in values {
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  account != Self.account else { continue }
            let deleteStatus = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw PairingError.keychainFailure(deleteStatus)
            }
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

private extension Data {
    func readUInt8(at cursor: inout Int) -> UInt8? {
        guard cursor < count else { return nil }
        defer { cursor += 1 }
        return self[cursor]
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
