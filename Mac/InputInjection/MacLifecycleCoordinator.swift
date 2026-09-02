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

#if os(macOS)
import AppKit

/// Thin menu-bar presentation adapter.  It has no independent connection or
/// pause state; each update derives from MacLifecycleCoordinator.status().
@MainActor
public final class RemoteControlStatusItemController: NSObject {
    private let coordinator: MacLifecycleCoordinator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let pauseItem = NSMenuItem()
    private let statusItemTitle = NSMenuItem()

    public init(coordinator: MacLifecycleCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "Remote"
        statusItemTitle.isEnabled = false
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(statusItemTitle)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        update()
    }

    public func update() {
        let status = coordinator.status()
        statusItemTitle.title = status.title
        pauseItem.title = status == .paused ? "Resume Remote Control" : "Pause Remote Control"
    }

    @objc private func togglePause() {
        if coordinator.status() == .paused {
            _ = coordinator.handle(.userResume)
        } else {
            _ = coordinator.handle(.userPause)
        }
        update()
    }

    @objc private func quit() {
        _ = coordinator.handle(.appWillTerminate)
        NSApplication.shared.terminate(nil)
    }
}
#endif

/// A small reconnect gate that can be used by the BLE/pairing layer without
/// importing either implementation.  It requires both applications to be
/// active and a previously trusted identity; authentication remains a fresh
/// handshake concern of the pairing layer.
public struct TrustedReconnectGate: Equatable, Sendable {
    public var trustedDevicePresent: Bool
    public var macAppActive: Bool
    public var phoneAppActive: Bool
    public var bluetoothPoweredOn: Bool

    public init(
        trustedDevicePresent: Bool = false,
        macAppActive: Bool = false,
        phoneAppActive: Bool = false,
        bluetoothPoweredOn: Bool = false
    ) {
        self.trustedDevicePresent = trustedDevicePresent
        self.macAppActive = macAppActive
        self.phoneAppActive = phoneAppActive
        self.bluetoothPoweredOn = bluetoothPoweredOn
    }

    public var mayAttemptReconnect: Bool {
        trustedDevicePresent && macAppActive && phoneAppActive && bluetoothPoweredOn
    }
}
