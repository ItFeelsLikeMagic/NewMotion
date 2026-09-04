import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// iPhone integration boundary. Scanner confirmation is the explicit user
/// action that permits a one-time BLE handshake; trusted reconnects still use
/// a new ephemeral exchange and never auto-trust a new identity.
public final class IPhonePairingCoordinator {
    public private(set) var trustedDevices: [TrustedDeviceSummary] = []
    public let identity: PairingIdentity
    public var onConfirmedPairing: ((PairingToken, PairingIdentity, PairingHandshakeClient) -> Void)?

    private let trust: TrustedDeviceManager
    private let clock: PairingClock
    private let random: PairingRandomSource

    public init(
        store: TrustedDeviceStore,
        identity: PairingIdentity? = nil,
        clock: PairingClock = SystemPairingClock(),
        random: PairingRandomSource = SystemPairingRandomSource()
    ) throws {
        self.clock = clock
        self.random = random
        self.trust = TrustedDeviceManager(store: store, clock: clock)
        if let identity {
            self.identity = identity
        } else {
            self.identity = try trust.existingIdentity() ?? trust.newIdentity()
        }
        self.trustedDevices = try trust.list()
    }

    public func attach(scanner: IPhonePairingScanner) {
        scanner.onConfirmed = { [weak self] token in self?.beginOneTimeHandshake(token: token) }
    }

    public func beginOneTimeHandshake(token: PairingToken) {
        do {
            let client = try PairingHandshakeClient(
                mode: .oneTime(token),
                identity: identity,
                clock: clock,
                random: random
            )
            onConfirmedPairing?(token, identity, client)
        } catch {
            // Construction can fail only for local key/random failures. The
            // caller maps it to a safe pairing error and leaves BLE stopped.
        }
    }

    public func makeReconnectClient(for deviceID: UUID) throws -> PairingHandshakeClient {
        let context = try trust.reconnectContext(for: deviceID)
        return try PairingHandshakeClient(
            mode: context.mode,
            identity: context.identity,
            clock: clock,
            random: random
        )
    }

    @discardableResult
    public func rememberPairedMac(
        deviceID: UUID,
        displayName: String,
        peerIdentityPublicKey: Data
    ) throws -> TrustedDeviceSummary {
        let summary = try trust.remember(
            deviceID: deviceID,
            displayName: displayName,
            peerIdentityPublicKey: peerIdentityPublicKey,
            localIdentity: identity
        )
        trustedDevices = try trust.list()
        return summary
    }

    public func revoke(deviceID: UUID) throws {
        try trust.revoke(deviceID: deviceID)
        trustedDevices = try trust.list()
    }
}
