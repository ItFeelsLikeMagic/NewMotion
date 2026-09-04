import Foundation

public enum PhoneLifecycleEvent: Equatable, Sendable {
    case startup
    case foreground
    case background
    case transportUnavailable
    case transportAvailable
    case transportDisconnected
    case trustAdded
    case trustRevoked
    case audioInterruption
    case motionInterruption
    case appWillTerminate
}

public enum PhoneSafeState: String, Equatable, Sendable {
    case inactive
    case foreground
    case disconnected
    case reconnecting
}

public struct PhoneLifecycleTransition: Equatable, Sendable {
    public let event: PhoneLifecycleEvent
    public let state: PhoneSafeState
    public let sensorsStopped: Bool
    public let reconnectEligible: Bool
    public let reconnectAttempted: Bool

    public init(
        event: PhoneLifecycleEvent,
        state: PhoneSafeState,
        sensorsStopped: Bool,
        reconnectEligible: Bool,
        reconnectAttempted: Bool
    ) {
        self.event = event
        self.state = state
        self.sensorsStopped = sensorsStopped
        self.reconnectEligible = reconnectEligible
        self.reconnectAttempted = reconnectAttempted
    }
}

/// Coordinates iPhone foreground/transport/trust transitions without importing
/// link or pairing implementations.  Reconnect is offered only for a known
/// trust record, active foreground apps, and an available transport; the
/// pairing layer still performs a fresh authenticated handshake.
public final class PhoneLifecycleCoordinator {
    private let motion: PhoneLifecycleStopping?
    private let audio: PhoneLifecycleStopping?
    private let disconnectTransport: () -> Void
    private let attemptReconnect: () -> Void

    private(set) public var state: PhoneSafeState = .inactive
    private(set) public var appForegrounded = false
    private(set) public var transportAvailable = false
    private(set) public var trustedDevicePresent = false

    public init(
        motion: PhoneLifecycleStopping? = nil,
        audio: PhoneLifecycleStopping? = nil,
        disconnectTransport: @escaping () -> Void = {},
        attemptReconnect: @escaping () -> Void = {}
    ) {
        self.motion = motion
        self.audio = audio
        self.disconnectTransport = disconnectTransport
        self.attemptReconnect = attemptReconnect
    }

    public var reconnectEligible: Bool {
        appForegrounded && transportAvailable && trustedDevicePresent
    }

    @discardableResult
    public func handle(_ event: PhoneLifecycleEvent) -> PhoneLifecycleTransition {
        var sensorsStopped = false
        var reconnectAttempted = false

        switch event {
        case .startup:
            stopResources()
            sensorsStopped = true
            disconnectTransport()
            state = .inactive
            appForegrounded = false

        case .foreground:
            appForegrounded = true
            state = .foreground
            if reconnectEligible {
                state = .reconnecting
                attemptReconnect()
                reconnectAttempted = true
            }

        case .background:
            appForegrounded = false
            stopResources()
            sensorsStopped = true
            disconnectTransport()
            state = .inactive

        case .transportUnavailable:
            transportAvailable = false
            stopResources()
            sensorsStopped = true
            disconnectTransport()
            state = .disconnected

        case .transportAvailable:
            transportAvailable = true
            state = appForegrounded ? .foreground : .inactive
            if reconnectEligible {
                state = .reconnecting
                attemptReconnect()
                reconnectAttempted = true
            }

        case .transportDisconnected:
            stopResources()
            sensorsStopped = true
            state = .disconnected

        case .trustAdded:
            trustedDevicePresent = true
            state = appForegrounded ? .foreground : .inactive
            if reconnectEligible {
                state = .reconnecting
                attemptReconnect()
                reconnectAttempted = true
            }

        case .trustRevoked:
            trustedDevicePresent = false
            stopResources()
            sensorsStopped = true
            disconnectTransport()
            state = .disconnected

        case .audioInterruption:
            audio?.stopForLifecycle()
            sensorsStopped = true

        case .motionInterruption:
            motion?.stopForLifecycle()
            sensorsStopped = true

        case .appWillTerminate:
            appForegrounded = false
            stopResources()
            sensorsStopped = true
            disconnectTransport()
            state = .inactive
        }

        if appForegrounded {
            audio?.resumeForLifecycle()
        }

        return PhoneLifecycleTransition(
            event: event,
            state: state,
            sensorsStopped: sensorsStopped,
            reconnectEligible: reconnectEligible,
            reconnectAttempted: reconnectAttempted
        )
    }

    private func stopResources() {
        motion?.stopForLifecycle()
        audio?.stopForLifecycle()
    }
}

extension LocalPushToTalkAudioController: PhoneLifecycleStopping {
    public func stopForLifecycle() {
        applicationDidEnterBackground()
    }

    public func resumeForLifecycle() {
        applicationWillEnterForeground()
    }
}
