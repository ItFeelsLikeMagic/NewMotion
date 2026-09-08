import Foundation

public struct TrustedDeviceSummary: Equatable {
    public let deviceID: UUID
    public let displayName: String
    public let pairedAt: Date
    /// The peer's long-term identity key, and the only thing here that names
    /// the same physical device across pairings. `deviceID` is the pairing ID,
    /// which is minted fresh for every QR code.
    public let peerIdentityPublicKey: Data

    public init(deviceID: UUID, displayName: String, pairedAt: Date, peerIdentityPublicKey: Data) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.pairedAt = pairedAt
        self.peerIdentityPublicKey = peerIdentityPublicKey
    }
}

/// Platform-neutral trust operations. The actual app decides when a QR
/// confirmation and authenticated handshake have succeeded, then calls
/// `remember`. A BLE identifier or display name alone is never sufficient.
public final class TrustedDeviceManager {
    private let store: TrustedDeviceStore
    private let clock: PairingClock

    public init(store: TrustedDeviceStore, clock: PairingClock = SystemPairingClock()) {
        self.store = store
        self.clock = clock
    }

    public func newIdentity() -> PairingIdentity { PairingIdentity() }

    /// Returns the long-term local identity carried by an existing trust
    /// record. A fresh identity is created by the platform coordinator only
    /// when no record exists yet; this keeps a Mac restart from changing the
    /// identity used by already-paired phones without adding another storage
    /// schema to the MVP.
    public func existingIdentity() throws -> PairingIdentity? {
        guard let record = try store.allRecords().first else { return nil }
        return try PairingIdentity(rawPrivateKey: record.localIdentityPrivateKey)
    }

    @discardableResult
    public func remember(
        deviceID: UUID,
        displayName: String,
        peerIdentityPublicKey: Data,
        localIdentity: PairingIdentity
    ) throws -> TrustedDeviceSummary {
        let record = try TrustedDeviceRecord(
            deviceID: deviceID,
            displayName: displayName,
            peerIdentityPublicKey: peerIdentityPublicKey,
            localIdentityPrivateKey: localIdentity.rawPrivateKey,
            pairedAt: clock.now
        )
        // Re-pairing the same peer supersedes the old record rather than
        // adding one. Each stale record is a beacon the other side keeps
        // scanning for, and a duplicate row in the device picker.
        for superseded in try store.allRecords()
        where superseded.peerIdentityPublicKey == peerIdentityPublicKey && superseded.deviceID != deviceID {
            try store.delete(deviceID: superseded.deviceID)
        }
        try store.save(record)
        return Self.summary(record)
    }

    public func reconnectContext(for deviceID: UUID) throws -> (identity: PairingIdentity, mode: HandshakeMode) {
        guard let record = try store.record(for: deviceID) else { throw PairingError.tokenNotActive }
        let identity = try PairingIdentity(rawPrivateKey: record.localIdentityPrivateKey)
        return (
            identity,
            .trusted(deviceID: record.deviceID, peerIdentityPublicKey: record.peerIdentityPublicKey)
        )
    }

    /// One entry per peer, newest pairing winning. Records written before
    /// `remember` began superseding them are collapsed here, so an existing
    /// pile of duplicates does not have to be re-paired away to disappear.
    /// The surviving `deviceID` is the newest, which is the beacon the peer
    /// most recently issued.
    public func list() throws -> [TrustedDeviceSummary] {
        var newestByPeer: [Data: TrustedDeviceRecord] = [:]
        for record in try store.allRecords() {
            let incumbent = newestByPeer[record.peerIdentityPublicKey]
            if incumbent == nil || record.pairedAt > incumbent!.pairedAt {
                newestByPeer[record.peerIdentityPublicKey] = record
            }
        }
        return newestByPeer.values.sorted { $0.pairedAt < $1.pairedAt }.map(Self.summary)
    }

    public func isTrusted(deviceID: UUID) throws -> Bool {
        try store.record(for: deviceID) != nil
    }

    /// Revoking a device drops every record for that peer, not just the one
    /// row the picker showed, so a forgotten Mac cannot come back through a
    /// stale duplicate.
    public func revoke(deviceID: UUID) throws {
        guard let record = try store.record(for: deviceID) else { return }
        for sibling in try store.allRecords()
        where sibling.peerIdentityPublicKey == record.peerIdentityPublicKey {
            try store.delete(deviceID: sibling.deviceID)
        }
    }

    private static func summary(_ record: TrustedDeviceRecord) -> TrustedDeviceSummary {
        TrustedDeviceSummary(
            deviceID: record.deviceID,
            displayName: record.displayName,
            pairedAt: record.pairedAt,
            peerIdentityPublicKey: record.peerIdentityPublicKey
        )
    }
}
