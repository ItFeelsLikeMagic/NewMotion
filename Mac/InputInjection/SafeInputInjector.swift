import Foundation

public enum InputInjectionResult: Equatable, Sendable {
    case applied
    case denied(SafetyDenialReason)
    case failed
}

/// Bridges the pure policy to an injected event sink.  No caller can post an
/// event without first passing through InputSafetyStateMachine.evaluate(_:).
public final class SafeInputInjector {
    private var policy: InputSafetyStateMachine
    private let sink: InputEventSink
    private let accessibility: AccessibilityTrustProviding?

    public init(
        policy: InputSafetyStateMachine = InputSafetyStateMachine(),
        sink: InputEventSink,
        accessibility: AccessibilityTrustProviding? = nil
    ) {
        self.policy = policy
        self.sink = sink
        self.accessibility = accessibility
    }

    public var state: InputControlState { policy.state }
    public var held: HeldInputState { policy.held }

    @discardableResult
    public func transition(to newState: InputControlState) -> SafetyTransitionResult {
        let heldBefore = policy.held
        let result = policy.transition(to: newState)
        performReleaseActions(result.actions, held: heldBefore)
        return result
    }

    /// Refreshes the platform Accessibility state and enters a denied state if
    /// permission was revoked.  Prompting is explicit and only requests AX.
    @discardableResult
    public func refreshAccessibility(prompt: Bool = false) -> AccessibilityState {
        guard let accessibility else { return policy.state.accessibility }
        let next: AccessibilityState = accessibility.isTrusted(prompt: prompt) ? .granted : .denied
        var state = policy.state
        state.accessibility = next
        transition(to: state)
        return next
    }

    @discardableResult
    public func submit(_ command: RemoteInputCommand) -> InputInjectionResult {
        if let accessibility, !accessibility.isTrusted(prompt: false) {
            var state = policy.state
            state.accessibility = .denied
            transition(to: state)
        }

        let decision = policy.evaluate(command)
        guard case let .allow(allowedCommand) = decision else {
            if case let .deny(reason) = decision { return .denied(reason) }
            return .denied(.invalidCommand)
        }

        do {
            try post(allowedCommand)
            return .applied
        } catch {
            // A partial physical action is unsafe.  Clear the policy state and
            // emit one idempotent release action before reporting the failure.
            let heldBefore = policy.held
            let action = policy.releaseAllInputs(reason: .explicit)
            performReleaseActions([action], held: heldBefore)
            return .failed
        }
    }

    /// Releases all physical button/modifier state.  This is safe to call for
    /// disconnect, sleep, shutdown, watchdog expiry, and repeated callbacks.
    @discardableResult
    public func releaseAllInputs(reason: ReleaseReason = .explicit) -> InputInjectionResult {
        let heldBefore = policy.held
        let action = policy.releaseAllInputs(reason: reason)
        performReleaseActions([action], held: heldBefore)
        return .applied
    }

    public func pause() {
        var next = policy.state
        next.activity = .paused
        _ = transition(to: next)
    }

    public func resume() {
        var next = policy.state
        next.activity = .active
        _ = transition(to: next)
    }

    /// Reconciles the remote held-state heartbeat through the normal command
    /// path.  No direct sink calls are made here.
    @discardableResult
    public func reconcile(held desired: HeldInputState) -> [InputInjectionResult] {
        let commands = policy.reconcile(held: desired)
        return commands.map { submit($0) }
    }

    private func post(_ command: RemoteInputCommand) throws {
        switch command {
        case let .pointer(delta):
            try sink.send(.pointer(delta: delta))
        case let .scroll(delta):
            try sink.send(.scroll(delta: delta))
        case let .mouseButton(button, isDown):
            try sink.send(.mouseButton(button: button, isDown: isDown))
        case let .doubleClick(button):
            try sink.send(.mouseDoubleClick(button: button))
        case let .modifier(key, isDown):
            try sink.send(.modifier(key: key, isDown: isDown))
        case let .text(value):
            try sink.send(.unicodeText(value))
        case let .hotkey(hotkey):
            try sink.send(.hotkey(HotkeyPhysicalSequence.transitions(for: hotkey)))
        }
    }

    private func performReleaseActions(_ actions: [SafetyAction], held: HeldInputState) {
        for action in actions {
            guard case .releaseAllInputs = action else { continue }
            // Release in a deterministic order.  Only state that was held is
            // posted, avoiding unrelated mouse-up/key-up events.
            for button in MacMouseButton.allCases where held.buttons.contains(button) {
                try? sink.send(.mouseButton(button: button, isDown: false))
            }
            for key in MacModifierKey.allCases where held.modifiers.contains(key) {
                try? sink.send(.modifier(key: key, isDown: false))
            }
        }
    }
}

public struct PhysicalKeyTransition: Equatable, Sendable {
    public let keyCode: UInt16
    public let isDown: Bool

    public init(keyCode: UInt16, isDown: Bool) {
        self.keyCode = keyCode
        self.isDown = isDown
    }
}

/// Physical key-code mapping is kept on the Mac side and selected only from
/// the fixed protocol allowlist.
public enum HotkeyPhysicalSequence {
    public static func transitions(for hotkey: MacAllowedHotkey) -> [PhysicalKeyTransition] {
        let commandKey: UInt16 = 55
        let key: UInt16
        let modifiers: [UInt16]

        switch hotkey {
        case .copy: key = 8; modifiers = [commandKey]
        case .paste: key = 9; modifiers = [commandKey]
        case .undo: key = 6; modifiers = [commandKey]
        case .redo: key = 6; modifiers = [commandKey, 56] // Shift + Command + Z
        case .selectAll: key = 0; modifiers = [commandKey]
        case .escape: key = 53; modifiers = []
        case .return: key = 36; modifiers = []
        case .tab: key = 48; modifiers = []
        case .arrowUp: key = 126; modifiers = []
        case .arrowDown: key = 125; modifiers = []
        case .arrowLeft: key = 123; modifiers = []
        case .arrowRight: key = 124; modifiers = []
        case .deleteBackward: key = 51; modifiers = []
        case .deleteWordBackward: key = 51; modifiers = [58] // Option + Delete
        case .deleteLineBackward: key = 51; modifiers = [commandKey]
        case .shiftTab: key = 48; modifiers = [56]
        // Control + Up is the stock Mission Control shortcut. If it has been
        // remapped in System Settings, the swipe does what that keyboard
        // shortcut now does, exactly as the keys themselves would.
        case .missionControl: key = 126; modifiers = [59]
        case .appExpose: key = 125; modifiers = [59]
        }

        var result = modifiers.map { PhysicalKeyTransition(keyCode: $0, isDown: true) }
        result.append(PhysicalKeyTransition(keyCode: key, isDown: true))
        result.append(PhysicalKeyTransition(keyCode: key, isDown: false))
        result.append(contentsOf: modifiers.reversed().map { PhysicalKeyTransition(keyCode: $0, isDown: false) })
        return result
    }
}
