import Foundation

public struct TrustedDeviceSummary: Equatable {
    public let deviceID: UUID
    public let displayName: String
    public let pairedAt: Date

    public init(deviceID: UUID, displayName: String, pairedAt: Date) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.pairedAt = pairedAt
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
        try store.save(record)
        return TrustedDeviceSummary(deviceID: record.deviceID, displayName: record.displayName, pairedAt: record.pairedAt)
    }

    public func reconnectContext(for deviceID: UUID) throws -> (identity: PairingIdentity, mode: HandshakeMode) {
        guard let record = try store.record(for: deviceID) else { throw PairingError.tokenNotActive }
        let identity = try PairingIdentity(rawPrivateKey: record.localIdentityPrivateKey)
        return (
            identity,
            .trusted(deviceID: record.deviceID, peerIdentityPublicKey: record.peerIdentityPublicKey)
        )
    }

    public func list() throws -> [TrustedDeviceSummary] {
        try store.allRecords().map { TrustedDeviceSummary(deviceID: $0.deviceID, displayName: $0.displayName, pairedAt: $0.pairedAt) }
    }

    public func isTrusted(deviceID: UUID) throws -> Bool {
        try store.record(for: deviceID) != nil
    }

    public func revoke(deviceID: UUID) throws { try store.delete(deviceID: deviceID) }

}
