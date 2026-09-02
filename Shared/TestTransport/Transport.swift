/// The transport contract consumed by protocol/features. It is intentionally
/// expressed as byte arrays so Core Bluetooth remains outside the shared layer.
public protocol RemoteTransportEndpoint: AnyObject {
    var isConnected: Bool { get }
    var onReceive: (([UInt8]) -> Void)? { get set }
    var onStateChange: ((TransportConnectionState) -> Void)? { get set }

    @discardableResult
    func send(_ bytes: [UInt8]) -> TransportSendResult
    func disconnect()
}

public enum TransportConnectionState: Equatable, Sendable {
    case disconnected
    case connected
}

public enum TransportSendResult: Equatable, Sendable {
    case queued
    case dropped
    case overflow
    case disconnected
}
