import Foundation
import CryptoKit
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// Mac integration boundary for QR pairing and trusted reconnect. UI and BLE
/// code provide the handshake bytes; this coordinator owns trust persistence
/// and ensures reconnects use a fresh ephemeral key and authenticated mode.
public final class MacPairingCoordinator {
    public let offerController: MacPairingOfferController
    public let identity: PairingIdentity
    public private(set) var trustedDevices: [TrustedDeviceSummary] = []

    private let trust: TrustedDeviceManager
    private let random: PairingRandomSource
    private let clock: PairingClock

    public init(
        store: TrustedDeviceStore,
        offerController: MacPairingOfferController? = nil,
        clock: PairingClock = SystemPairingClock(),
        random: PairingRandomSource = SystemPairingRandomSource()
    ) throws {
        self.clock = clock
        self.random = random
        self.trust = TrustedDeviceManager(store: store, clock: clock)
        self.offerController = offerController ?? MacPairingOfferController(clock: clock)
        self.identity = try trust.existingIdentity() ?? PairingIdentity()
        self.trustedDevices = try trust.list()
    }

    public func refreshTrustedDevices() throws -> [TrustedDeviceSummary] {
        trustedDevices = try trust.list()
        return trustedDevices
    }

    public func issueOffer(displayName: String, lifetime: TimeInterval = PairingToken.maximumLifetime) throws -> PairingOffer {
        try offerController.issue(displayName: displayName, lifetime: lifetime)
    }

    /// Creates the one-time server using the private key retained by the
    /// currently displayed QR offer. The offer is consumed atomically by the
    /// pairing identifier presented in the phone's client hello.
    public func makeOneTimeServer(pairingID: UUID) throws -> PairingHandshakeServer {
        let offer = try offerController.consume(pairingID: pairingID)
        return PairingHandshakeServer(
            mode: .oneTime(offer.token),
            identity: identity,
            clock: clock,
            random: random,
            ephemeralPrivateKey: offer.macEphemeralPrivateKey
        )
    }

    /// Called only after the BLE authenticated handshake has completed. The
    /// caller must pass the peer identity returned by PairingHandshakeResult;
    /// QR/BLE identifiers are not accepted as a trust substitute.
    @discardableResult
    public func rememberPairedPhone(
        deviceID: UUID,
        displayName: String,
        peerIdentityPublicKey: Data,
        localIdentity: PairingIdentity
    ) throws -> TrustedDeviceSummary {
        let summary = try trust.remember(
            deviceID: deviceID,
            displayName: displayName,
            peerIdentityPublicKey: peerIdentityPublicKey,
            localIdentity: localIdentity
        )
        trustedDevices = try trust.list()
        return summary
    }

    /// Convenience overload for the normal first-pairing path. The
    /// coordinator's stable Mac identity is persisted in the trust record.
    @discardableResult
    public func rememberPairedPhone(
        deviceID: UUID,
        displayName: String,
        peerIdentityPublicKey: Data
    ) throws -> TrustedDeviceSummary {
        try rememberPairedPhone(
            deviceID: deviceID,
            displayName: displayName,
            peerIdentityPublicKey: peerIdentityPublicKey,
            localIdentity: identity
        )
    }

    public func makeHandshakeServer(pairingID: UUID) throws -> PairingHandshakeServer {
        do {
            return try makeOneTimeServer(pairingID: pairingID)
        } catch PairingError.tokenNotActive {
            return try makeReconnectServer(for: pairingID)
        }
    }

    public func makeReconnectServer(for deviceID: UUID) throws -> PairingHandshakeServer {
        let context = try trust.reconnectContext(for: deviceID)
        return PairingHandshakeServer(
            mode: context.mode,
            identity: context.identity,
            clock: clock,
            random: random,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
    }

    public func revoke(deviceID: UUID) throws {
        try trust.revoke(deviceID: deviceID)
        trustedDevices = try trust.list()
    }
}
