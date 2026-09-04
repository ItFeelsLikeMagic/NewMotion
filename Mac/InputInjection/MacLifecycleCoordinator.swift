import Foundation

public enum MacLifecycleEvent: Equatable, Sendable {
    case startup
    case authenticated
    case disconnected
    case lock
    case unlock
    case sleep
    case wake
    case logout
    case login
    case accessibilityChanged(AccessibilityState)
    case userPause
    case userResume
    case appWillTerminate
}

public enum ReconnectEligibility: String, Equatable, Sendable {
    case notEligible
    case eligibleWhenBothAppsActive
}

public enum RemoteMenuBarStatus: Equatable, Sendable {
    case disconnected
    case connected
    case paused
    case unsafe(SafetyDenialReason)

    public var title: String {
        switch self {
        case .disconnected: return "Remote: Disconnected"
        case .connected: return "Remote: Active"
        case .paused: return "Remote: Paused"
        case let .unsafe(reason): return "Remote: Unsafe (\(reason.rawValue))"
        }
    }
}

public struct LifecycleTransitionResult: Equatable, Sendable {
    public let event: MacLifecycleEvent
    public let state: InputControlState
    public let released: Bool
    public let reconnect: ReconnectEligibility
    public let status: RemoteMenuBarStatus

    public init(
        event: MacLifecycleEvent,
        state: InputControlState,
        released: Bool,
        reconnect: ReconnectEligibility,
        status: RemoteMenuBarStatus
    ) {
        self.event = event
        self.state = state
        self.released = released
        self.reconnect = reconnect
        self.status = status
    }
}

/// Centralizes platform lifecycle mapping.  The menu-bar view and reconnect
/// layer read the resulting state rather than maintaining independent flags.
public final class MacLifecycleCoordinator {
    private let injector: SafeInputInjector
    private(set) public var reconnectEligibility: ReconnectEligibility = .notEligible

    public init(injector: SafeInputInjector) {
        self.injector = injector
    }

    @discardableResult
    public func handle(_ event: MacLifecycleEvent) -> LifecycleTransitionResult {
        var released = false
        switch event {
        case .startup:
            _ = injector.transition(to: .startup)
            _ = injector.releaseAllInputs(reason: .startup)
            released = true
            reconnectEligibility = .notEligible

        case .authenticated:
            var state = injector.state
            state.authentication = .authenticated
            _ = injector.transition(to: state)
            reconnectEligibility = .eligibleWhenBothAppsActive

        case .disconnected:
            var state = injector.state
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            released = true
            reconnectEligibility = .notEligible

        case .lock:
            var state = injector.state
            state.lock = .locked
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            released = true
            reconnectEligibility = .eligibleWhenBothAppsActive

        case .unlock:
            var state = injector.state
            state.lock = .unlocked
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            reconnectEligibility = .eligibleWhenBothAppsActive

        case .sleep:
            var state = injector.state
            state.power = .asleep
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            released = true
            reconnectEligibility = .eligibleWhenBothAppsActive

        case .wake:
            var state = injector.state
            state.power = .awake
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            reconnectEligibility = .eligibleWhenBothAppsActive

        case .logout:
            var state = injector.state
            state.login = .loggedOut
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            released = true
            reconnectEligibility = .notEligible

        case .login:
            var state = injector.state
            state.login = .loggedIn
            state.authentication = .unauthenticated
            _ = injector.transition(to: state)
            reconnectEligibility = .eligibleWhenBothAppsActive

        case let .accessibilityChanged(accessibility):
            var state = injector.state
            state.accessibility = accessibility
            _ = injector.transition(to: state)
            released = accessibility != .granted
            if accessibility != .granted { reconnectEligibility = .notEligible }

        case .userPause:
            injector.pause()
            released = true

        case .userResume:
            injector.resume()

        case .appWillTerminate:
            _ = injector.releaseAllInputs(reason: .appTermination)
            var state = injector.state
            state.authentication = .unauthenticated
            state.activity = .paused
            _ = injector.transition(to: state)
            released = true
            reconnectEligibility = .notEligible
        }

        return LifecycleTransitionResult(
            event: event,
            state: injector.state,
            released: released,
            reconnect: reconnectEligibility,
            status: status(for: injector.state)
        )
    }

    public func status() -> RemoteMenuBarStatus {
        status(for: injector.state)
    }

    private func status(for state: InputControlState) -> RemoteMenuBarStatus {
        if state.activity == .paused { return .paused }
        if state.authentication != .authenticated { return .disconnected }
        if state.accessibility != .granted {
            return .unsafe(state.denialReason ?? .accessibilityUnavailable)
        }
        guard state.isControllable else { return .unsafe(state.denialReason ?? .unsupportedCommand) }
        return .connected
    }
}
