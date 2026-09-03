import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared

/// Converts the framework-neutral Mac safety commands to the stable shared
/// protocol types.  The feature/policy module stays testable without the
/// generated project while the app target gets an explicit wire bridge.
public enum SharedInputProtocolAdapter {
    public static func payload(for command: RemoteInputCommand) throws -> MessagePayload {
        switch command {
        case let .pointer(delta):
            return .pointerDelta(PointerDeltaPayload(
                deltaX: try checkedInt16(delta.x),
                deltaY: try checkedInt16(delta.y)
            ))
        case let .scroll(delta):
            return .scrollDelta(ScrollDeltaPayload(
                deltaX: try checkedInt16(delta.x),
                deltaY: try checkedInt16(delta.y)
            ))
        case let .mouseButton(button, isDown):
            return .mouseButton(MouseButtonPayload(
                button: button,
                isDown: isDown
            ))
        case let .doubleClick(button):
            return .mouseDoubleClick(MouseDoubleClickPayload(button: button))
        case let .text(value):
            return .textInput(try TextInputPayload(text: value))
        case let .hotkey(hotkey):
            return .hotkey(HotkeyPayload(action: sharedHotkey(hotkey)))
        case .modifier:
            // The current shared protocol represents hotkeys atomically and
            // does not expose long-held modifier messages.  Modifiers are
            // still tracked by the safety layer for release/watchdog safety;
            // callers must encode them as one of the allowlisted hotkeys.
            throw ProtocolAdapterError.modifierNotRepresented
        }
    }

    public static func heartbeat(for held: HeldInputState, isActive: Bool = true) -> HeartbeatPayload {
        var buttons: UInt8 = 0
        if held.buttons.contains(.left) { buttons |= 1 }
        if held.buttons.contains(.right) { buttons |= 2 }
        var modifiers: UInt8 = 0
        if held.modifiers.contains(.command) { modifiers |= 1 }
        if held.modifiers.contains(.option) { modifiers |= 2 }
        if held.modifiers.contains(.control) { modifiers |= 4 }
        if held.modifiers.contains(.shift) { modifiers |= 8 }
        return HeartbeatPayload(isActive: isActive, buttons: buttons, modifiers: modifiers)
    }

    /// Decodes the input subset received from the phone into the local safety
    /// command vocabulary.  The caller must still pass the command through
    /// `InputSafetyStateMachine`/`SafeInputInjector`; this method never posts
    /// an event or bypasses policy.
    public static func command(for payload: MessagePayload) throws -> RemoteInputCommand {
        switch payload {
        case let .pointerDelta(value):
            return .pointer(MacPointerDelta(x: Double(value.deltaX), y: Double(value.deltaY)))
        case let .motionPointerDelta(value):
            return .pointer(MacPointerDelta(x: Double(value.deltaX), y: Double(value.deltaY)))
        case let .scrollDelta(value):
            return .scroll(MacScrollDelta(x: Double(value.deltaX), y: Double(value.deltaY)))
        case let .mouseButton(value):
            return .mouseButton(button: value.button, isDown: value.isDown)
        case let .mouseDoubleClick(value):
            return .doubleClick(value.button)
        case let .textInput(value):
            guard let text = value.text else { throw ProtocolAdapterError.invalidPayload }
            return .text(text)
        case let .hotkey(value):
            return .hotkey(localHotkey(value.action))
        case .heartbeat, .appSwitcher, .audioChunk, .acknowledgement, .connectionStatus, .error, .ping, .pong:
            throw ProtocolAdapterError.unsupportedMessage
        }
    }

    /// The switcher is the one remote action that spans several messages. Each
    /// phase still expands into ordinary commands, so every event it produces
    /// passes the same policy checks and the held Command is tracked for
    /// release like any other.
    public static func commands(for phase: AppSwitcherPhase) -> [RemoteInputCommand] {
        switch phase {
        case .begin:
            return [.modifier(key: .command, isDown: true), .hotkey(.tab)]
        case .next:
            return [.hotkey(.tab)]
        case .previous:
            return [.hotkey(.shiftTab)]
        case .commit:
            return [.modifier(key: .command, isDown: false)]
        case .cancel:
            return [.hotkey(.escape), .modifier(key: .command, isDown: false)]
        }
    }

    private static func checkedInt16(_ value: Double) throws -> Int16 {
        guard value.isFinite, value >= Double(Int16.min), value <= Double(Int16.max) else {
            throw ProtocolAdapterError.valueOutOfRange
        }
        return Int16(value.rounded())
    }

    private static func sharedHotkey(_ hotkey: MacAllowedHotkey) -> HotkeyAction {
        switch hotkey {
        case .copy: return .copy
        case .paste: return .paste
        case .undo: return .undo
        case .redo: return .redo
        case .selectAll: return .selectAll
        case .escape: return .escape
        case .return: return .returnKey
        case .tab: return .tab
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .deleteBackward: return .deleteBackward
        case .deleteWordBackward: return .deleteWordBackward
        case .deleteLineBackward: return .deleteLineBackward
        case .shiftTab: return .shiftTab
        }
    }

    private static func localHotkey(_ hotkey: HotkeyAction) -> MacAllowedHotkey {
        switch hotkey {
        case .copy: return .copy
        case .paste: return .paste
        case .undo: return .undo
        case .redo: return .redo
        case .selectAll: return .selectAll
        case .escape: return .escape
        case .returnKey: return .return
        case .tab: return .tab
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .deleteBackward: return .deleteBackward
        case .deleteWordBackward: return .deleteWordBackward
        case .deleteLineBackward: return .deleteLineBackward
        case .shiftTab: return .shiftTab
        }
    }
}

public enum ProtocolAdapterError: Error, Equatable, Sendable {
    case valueOutOfRange
    case modifierNotRepresented
    case invalidPayload
    case unsupportedMessage
}
#endif
