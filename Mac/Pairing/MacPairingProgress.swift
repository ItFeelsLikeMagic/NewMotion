import Foundation

/// User-facing progress for the Mac pairing path. BLE readiness is kept
/// separate from `.paired`: the latter is emitted only after the authenticated
/// X25519 handshake and trust-record write both succeed.
public enum MacPairingProgress: Equatable, Sendable {
    case idle
    case waitingForLink
    case scanning
    case waitingForConfirmation
    case discovered(deviceName: String)
    case connecting(deviceName: String)
    case connected(deviceName: String)
    case authenticating(deviceName: String)
    case paired(deviceName: String)
    case disconnected
    case failed

    public var title: String {
        switch self {
        case .idle: return "Ready to pair"
        case .waitingForLink: return "Waiting for Bluetooth"
        case .scanning: return "Looking for iPhone"
        case .waitingForConfirmation: return "Waiting for iPhone confirmation"
        case let .discovered(name): return "Found \(name)"
        case let .connecting(name): return "Connecting to \(name)"
        case let .connected(name): return "Connected to \(name)"
        case let .authenticating(name): return "Authenticating \(name)"
        case let .paired(name): return "Paired with \(name)"
        case .disconnected: return "Phone disconnected"
        case .failed: return "Pairing failed"
        }
    }

    public var deviceName: String? {
        switch self {
        case let .discovered(name), let .connecting(name), let .connected(name),
             let .authenticating(name), let .paired(name):
            return name
        case .idle, .waitingForLink, .scanning, .waitingForConfirmation,
             .disconnected, .failed:
            return nil
        }
    }

    public var isAuthenticated: Bool {
        if case .paired = self { return true }
        return false
    }

    public var kind: String {
        switch self {
        case .idle: return "idle"
        case .waitingForLink: return "waitingForLink"
        case .scanning: return "scanning"
        case .waitingForConfirmation: return "waitingForConfirmation"
        case .discovered: return "discovered"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .authenticating: return "authenticating"
        case .paired: return "paired"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        }
    }
}
