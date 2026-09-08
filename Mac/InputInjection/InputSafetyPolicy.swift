import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
public typealias MacMouseButton = NewMotionShared.MouseButton
#else
public enum MacMouseButton: String, CaseIterable, Hashable, Equatable, Sendable {
    case left
    case right
}
#endif

/// The states that are relevant to the input safety boundary.  These values are
/// deliberately framework-independent so that the policy can be exercised in
/// a simulator or a unit test without Accessibility or a window server.
public enum RemoteAuthenticationState: String, Equatable, Sendable {
    case unauthenticated
    case authenticated
}

public enum RemoteActivityState: String, Equatable, Sendable {
    case active
    case paused
}

public enum MacLockState: String, Equatable, Sendable {
    case unlocked
    case locked
}

public enum MacPowerState: String, Equatable, Sendable {
    case awake
    case asleep
}

public enum MacLoginState: String, Equatable, Sendable {
    case loggedIn
    case loggedOut
}

public enum AccessibilityState: String, Equatable, Sendable {
    case unknown
    case granted
    case denied
}

/// All conditions must be favorable before a remote command may be posted.
public struct InputControlState: Equatable, Sendable {
    public var authentication: RemoteAuthenticationState
    public var activity: RemoteActivityState
    public var lock: MacLockState
    public var power: MacPowerState
    public var login: MacLoginState
    public var accessibility: AccessibilityState

    public init(
        authentication: RemoteAuthenticationState = .unauthenticated,
        activity: RemoteActivityState = .active,
        lock: MacLockState = .unlocked,
        power: MacPowerState = .awake,
        login: MacLoginState = .loggedIn,
        accessibility: AccessibilityState = .unknown
    ) {
        self.authentication = authentication
        self.activity = activity
        self.lock = lock
        self.power = power
        self.login = login
        self.accessibility = accessibility
    }

    /// A startup state is safe even before platform state has been observed.
    public static let startup = InputControlState(
        authentication: .unauthenticated,
        activity: .active,
        lock: .unlocked,
        power: .awake,
        login: .loggedIn,
        accessibility: .unknown
    )

    public var isControllable: Bool {
        authentication == .authenticated &&
            activity == .active &&
            lock == .unlocked &&
            power == .awake &&
            login == .loggedIn &&
            accessibility == .granted
    }

    public var denialReason: SafetyDenialReason? {
        if authentication != .authenticated { return .unauthenticated }
        if activity != .active { return .paused }
        if lock != .unlocked { return .locked }
        if power != .awake { return .asleep }
        if login != .loggedIn { return .loggedOut }
        if accessibility != .granted { return .accessibilityUnavailable }
        return nil
    }
}

public enum MacModifierKey: String, CaseIterable, Hashable, Equatable, Sendable {
    case command
    case option
    case control
    case shift
    case function
}

/// The policy's local spelling of the protocol hotkey allowlist.  A focused
/// adapter maps these values to NewMotionShared.HotkeyAction when the shared
/// module is available.
public enum MacAllowedHotkey: String, CaseIterable, Hashable, Equatable, Sendable {
    case copy
    case paste
    case undo
    case redo
    case selectAll
    case escape
    case `return`
    case tab
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case deleteBackward
    case deleteWordBackward
    case deleteLineBackward
    case shiftTab
    case missionControl
    case appExpose
    case nextWindow
    case newItem
    case newTab
    case closeWindow
    case selectLeft
    case selectRight
    case selectUp
    case selectDown
    case controlCenter
}

public struct MacPointerDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MacScrollDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum InputCommandDelivery: String, Equatable, Sendable {
    case bestEffort
    case reliable
}

/// Protocol-facing commands after decoding.  There is no case for arbitrary
/// key codes, shell commands, macros, or application automation.
public enum RemoteInputCommand: Equatable, Sendable {
    case pointer(MacPointerDelta)
    case scroll(MacScrollDelta)
    /// `clickCount` is which click of a run the press continues.  Two makes a
    /// Mac widen a text selection by word while the drag goes on, three by
    /// line.  A release carries the same count as the press it ends.
    case mouseButton(button: MacMouseButton, isDown: Bool, clickCount: Int)
    /// One atomic press-and-release carrying a click count of two. It holds no
    /// button afterwards, so it needs no release bookkeeping.
    case doubleClick(MacMouseButton)
    case modifier(key: MacModifierKey, isDown: Bool)
    case text(String)
    case hotkey(MacAllowedHotkey)
    /// One hotkey pressed `times` over, as a single burst.  The remote has no
    /// way to ask for this; a held delete key's slide builds it on the Mac,
    /// where the number of presses is the very thing being counted.  Sending
    /// the run as one command is what keeps a word from taking a tenth of a
    /// second: the presses inside a run need no spacing from each other.
    case hotkeyRun(MacAllowedHotkey, times: Int)

    public var delivery: InputCommandDelivery {
        switch self {
        case .pointer, .scroll, .text:
            return .bestEffort
        case .mouseButton, .doubleClick, .modifier, .hotkey, .hotkeyRun:
            return .reliable
        }
    }
}

public enum SafetyDenialReason: String, Equatable, Sendable {
    case unauthenticated
    case paused
    case locked
    case asleep
    case loggedOut
    case accessibilityUnavailable
    case invalidCommand
    case emptyText
    case textTooLarge
    case nonFiniteValue
    case unsupportedCommand
}

public enum ReleaseReason: String, Equatable, Sendable {
    case startup
    case disconnect
    case heartbeatTimeout
    case lock
    case sleep
    case logout
    case pause
    case accessibilityRevoked
    case appTermination
    case lifecycleTransition
    case explicit
}

public struct HeldInputState: Equatable, Sendable {
    public fileprivate(set) var buttons: Set<MacMouseButton>
    public fileprivate(set) var modifiers: Set<MacModifierKey>

    public init(buttons: Set<MacMouseButton> = [], modifiers: Set<MacModifierKey> = []) {
        self.buttons = buttons
        self.modifiers = modifiers
    }

    public var isEmpty: Bool { buttons.isEmpty && modifiers.isEmpty }
}

public enum SafetyAction: Equatable, Sendable {
    /// The sink must release every tracked button and modifier.  This is a
    /// single idempotent action, rather than a collection of remote requests.
    case releaseAllInputs(reason: ReleaseReason)
}

public enum PolicyDecision: Equatable, Sendable {
    case allow(RemoteInputCommand)
    case deny(SafetyDenialReason)
}

public struct SafetyTransitionResult: Equatable, Sendable {
    public let previous: InputControlState
    public let current: InputControlState
    public let actions: [SafetyAction]

    public init(previous: InputControlState, current: InputControlState, actions: [SafetyAction]) {
        self.previous = previous
        self.current = current
        self.actions = actions
    }
}

public struct InputPolicyLimits: Equatable, Sendable {
    public var maxPointerComponent: Double
    public var maxScrollComponent: Double
    public var maxTextUTF8Bytes: Int
    /// Presses one command may ask for.  Longer than any word a delete key
    /// would take in one notch, and short enough that a bad number cannot hold
    /// the key queue for a noticeable time.
    public var maxHotkeyRun: Int

    public init(
        maxPointerComponent: Double = 10_000,
        maxScrollComponent: Double = 10_000,
        maxTextUTF8Bytes: Int = 4_096,
        maxHotkeyRun: Int = 64
    ) {
        self.maxPointerComponent = max(1, maxPointerComponent)
        self.maxScrollComponent = max(1, maxScrollComponent)
        self.maxTextUTF8Bytes = max(1, maxTextUTF8Bytes)
        self.maxHotkeyRun = max(1, maxHotkeyRun)
    }
}

/// Pure policy/state machine for the only command path that may reach an
/// event sink.  The state machine owns held state and is therefore the source
/// of truth for release decisions.
public struct InputSafetyStateMachine: Sendable {
    public private(set) var state: InputControlState
    public private(set) var held: HeldInputState
    public let limits: InputPolicyLimits

    public init(
        state: InputControlState = .startup,
        limits: InputPolicyLimits = InputPolicyLimits()
    ) {
        self.state = state
        self.held = HeldInputState()
        self.limits = limits
    }

    /// Applies a complete platform/control state snapshot.  A transition into
    /// an unsafe state emits one release action and clears held state.  The
    /// action is idempotent at the sink, so duplicate lifecycle notifications
    /// cannot strand a button or modifier.
    @discardableResult
    public mutating func transition(to newState: InputControlState) -> SafetyTransitionResult {
        let previous = state
        state = newState

        let enteredUnsafe = previous.isControllable && !newState.isControllable
        let changedWhileUnsafe = previous != newState && !newState.isControllable && !held.isEmpty
        if enteredUnsafe || changedWhileUnsafe {
            held = HeldInputState()
            return SafetyTransitionResult(
                previous: previous,
                current: newState,
                actions: [.releaseAllInputs(reason: releaseReason(for: newState))]
            )
        }

        return SafetyTransitionResult(previous: previous, current: newState, actions: [])
    }

    /// Handles a decoded command and updates held state only after all policy
    /// checks pass.  Platform events are posted by a separate adapter.
    public mutating func evaluate(_ command: RemoteInputCommand) -> PolicyDecision {
        guard state.isControllable else {
            return .deny(state.denialReason ?? .unsupportedCommand)
        }

        guard validate(command) else {
            return .deny(validationFailure(for: command))
        }

        switch command {
        case let .mouseButton(button, isDown, _):
            if isDown {
                held.buttons.insert(button)
            } else {
                held.buttons.remove(button)
            }
        case let .modifier(key, isDown):
            if isDown {
                held.modifiers.insert(key)
            } else {
                held.modifiers.remove(key)
            }
        case .pointer, .scroll, .text, .hotkey, .hotkeyRun, .doubleClick:
            break
        }
        return .allow(command)
    }

    /// Clears held state and returns one release action even if no state was
    /// held.  Callers may safely invoke this repeatedly.
    @discardableResult
    public mutating func releaseAllInputs(reason: ReleaseReason = .explicit) -> SafetyAction {
        held = HeldInputState()
        return .releaseAllInputs(reason: reason)
    }

    /// Reconciles the remote's current held-state heartbeat.  It returns the
    /// missing transitions that should be sent through the normal policy path.
    public mutating func reconcile(held desired: HeldInputState) -> [RemoteInputCommand] {
        guard state.isControllable else { return [] }

        var commands: [RemoteInputCommand] = []
        for button in MacMouseButton.allCases where held.buttons.contains(button) != desired.buttons.contains(button) {
            commands.append(.mouseButton(
                button: button,
                isDown: desired.buttons.contains(button),
                clickCount: 1
            ))
        }
        for modifier in MacModifierKey.allCases where held.modifiers.contains(modifier) != desired.modifiers.contains(modifier) {
            commands.append(.modifier(key: modifier, isDown: desired.modifiers.contains(modifier)))
        }
        return commands
    }

    private func validate(_ command: RemoteInputCommand) -> Bool {
        switch command {
        case let .pointer(delta):
            return finite(delta.x) && finite(delta.y) &&
                abs(delta.x) <= limits.maxPointerComponent &&
                abs(delta.y) <= limits.maxPointerComponent
        case let .scroll(delta):
            return finite(delta.x) && finite(delta.y) &&
                abs(delta.x) <= limits.maxScrollComponent &&
                abs(delta.y) <= limits.maxScrollComponent
        case let .text(value):
            return !value.isEmpty && value.utf8.count <= limits.maxTextUTF8Bytes
        case let .hotkeyRun(_, times):
            return times > 0 && times <= limits.maxHotkeyRun
        case .mouseButton, .doubleClick, .modifier, .hotkey:
            return true
        }
    }

    private func validationFailure(for command: RemoteInputCommand) -> SafetyDenialReason {
        switch command {
        case let .text(value):
            return value.isEmpty ? .emptyText : .textTooLarge
        case .pointer, .scroll:
            return .nonFiniteValue
        case .mouseButton, .doubleClick, .modifier, .hotkey, .hotkeyRun:
            return .invalidCommand
        }
    }

    private func finite(_ value: Double) -> Bool {
        value.isFinite
    }

    private func releaseReason(for state: InputControlState) -> ReleaseReason {
        if state.activity == .paused { return .pause }
        if state.lock == .locked { return .lock }
        if state.power == .asleep { return .sleep }
        if state.login == .loggedOut { return .logout }
        if state.accessibility != .granted { return .accessibilityRevoked }
        if state.authentication == .unauthenticated { return .disconnect }
        return .lifecycleTransition
    }
}
