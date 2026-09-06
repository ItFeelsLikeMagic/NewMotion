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
        case let .mouseButton(button, isDown, clickCount):
            return .mouseButton(MouseButtonPayload(
                button: button,
                isDown: isDown,
                clickCount: UInt8(clamping: clickCount)
            ))
        case let .doubleClick(button):
            return .mouseDoubleClick(MouseDoubleClickPayload(button: button))
        case let .text(value):
            return .textInput(try TextInputPayload(text: value))
        case let .hotkey(hotkey):
            return .hotkey(HotkeyPayload(action: sharedHotkey(hotkey)))
        case .hotkeyRun:
            // A run of presses is worked out on the Mac and never travels, so
            // the wire has no shape for it.
            throw ProtocolAdapterError.unsupportedMessage
        case .modifier:
            // The current shared protocol represents hotkeys atomically and
            // does not expose long-held modifier messages.  Modifiers are
            // still tracked by the safety layer for release/watchdog safety;
            // callers must encode them as one of the allowlisted hotkeys.
            throw ProtocolAdapterError.modifierNotRepresented
        }
    }

    /// The Mac's modifier vocabulary against the wire's, in one table, so the
    /// two directions cannot drift apart.  `.function` is absent on purpose:
    /// the protocol has no bit for it, and no remote command holds it, because
    /// every hotkey travels as one atomic press and release.
    private static let modifierBits: [MacModifierKey: HeldModifier] = [
        .command: .command,
        .option: .option,
        .control: .control,
        .shift: .shift
    ]

    public static func heartbeat(for held: HeldInputState, isActive: Bool = true) -> HeartbeatPayload {
        var buttons = HeldButtons()
        for button in held.buttons {
            buttons.insert(HeldButtons(button))
        }
        var modifiers = HeldModifiers()
        for key in held.modifiers {
            guard let bit = modifierBits[key] else { continue }
            modifiers.insert(HeldModifiers(bit))
        }
        return HeartbeatPayload(isActive: isActive, buttons: buttons, modifiers: modifiers)
    }

    /// What a heartbeat claims the remote is holding, in the safety layer's
    /// vocabulary.  Pass it to `SafeInputInjector.reconcile(held:)`, which
    /// posts only the difference against what the Mac actually holds, so a
    /// press or a release lost on the way is repaired by the next beat.
    public static func held(from payload: HeartbeatPayload) -> HeldInputState {
        var buttons: Set<MacMouseButton> = []
        for button in MacMouseButton.allCases where payload.heldButtons.contains(HeldButtons(button)) {
            buttons.insert(button)
        }
        var modifiers: Set<MacModifierKey> = []
        for (key, bit) in modifierBits where payload.heldModifiers.contains(HeldModifiers(bit)) {
            modifiers.insert(key)
        }
        return HeldInputState(buttons: buttons, modifiers: modifiers)
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
            return .mouseButton(
                button: value.button,
                isDown: value.isDown,
                clickCount: Int(value.clickCount)
            )
        case let .mouseDoubleClick(value):
            return .doubleClick(value.button)
        case let .textInput(value):
            guard let text = value.text else { throw ProtocolAdapterError.invalidPayload }
            return .text(text)
        case let .hotkey(value):
            return .hotkey(localHotkey(value.action))
        // `spokenText` is deliberately absent: dictation takes the transcript
        // path, which feeds the vocabulary cache and checks secure input first.
        // `vocabulary` only ever travels Mac to phone, so inbound it is junk.
        case .heartbeat, .tabWalk, .deleteScrub, .audioChunk, .spokenText,
             .vocabulary, .acknowledgement, .connectionStatus, .error, .ping, .pong:
            throw ProtocolAdapterError.unsupportedMessage
        }
    }

    /// The walk is the one remote action that spans several messages. Each
    /// phase still expands into ordinary commands, so every event it produces
    /// passes the same policy checks and the held modifier is tracked for
    /// release like any other.
    public static func commands(for payload: TabWalkPayload) -> [RemoteInputCommand] {
        let key = localModifier(payload.modifier)
        switch payload.phase {
        case .begin:
            return [.modifier(key: key, isDown: true), .hotkey(.tab)]
        case .next:
            return [.hotkey(.tab)]
        case .previous:
            return [.hotkey(.shiftTab)]
        case .commit:
            return [.modifier(key: key, isDown: false)]
        case .cancel:
            return [.hotkey(.escape), .modifier(key: key, isDown: false)]
        }
    }

    private static func localModifier(_ modifier: HeldModifier) -> MacModifierKey {
        modifierBits.first { $0.value == modifier }?.key ?? .command
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
        case .missionControl: return .missionControl
        case .appExpose: return .appExpose
        case .nextWindow: return .nextWindow
        case .newItem: return .newItem
        case .newTab: return .newTab
        case .closeWindow: return .closeWindow
        case .selectLeft: return .selectLeft
        case .selectRight: return .selectRight
        case .selectUp: return .selectUp
        case .selectDown: return .selectDown
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
        case .missionControl: return .missionControl
        case .appExpose: return .appExpose
        case .nextWindow: return .nextWindow
        case .newItem: return .newItem
        case .newTab: return .newTab
        case .closeWindow: return .closeWindow
        case .selectLeft: return .selectLeft
        case .selectRight: return .selectRight
        case .selectUp: return .selectUp
        case .selectDown: return .selectDown
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
