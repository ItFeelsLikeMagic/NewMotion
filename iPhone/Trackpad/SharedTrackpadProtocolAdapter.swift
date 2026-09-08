import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

public enum TrackpadProtocolAdapterError: Error, Equatable, Sendable {
    case valueOutOfRange
    case unsupportedOutput
}

/// Encodes trackpad output into shared protocol payloads without making the
/// gesture engine depend on Core Bluetooth or a generated transport.
public enum SharedTrackpadProtocolAdapter {
    /// A click expands to a complete down/up pair.  Callers should enqueue all
    /// returned payloads under one action ID when using reliable transport.
    public static func payloads(for output: RemoteInputEvent) throws -> [MessagePayload] {
        switch output {
        case let .pointer(delta):
            return [.pointerDelta(PointerDeltaPayload(
                deltaX: try int16(delta.x),
                deltaY: try int16(delta.y)
            ))]
        case let .scroll(delta):
            return [.scrollDelta(ScrollDeltaPayload(
                deltaX: try int16(delta.x),
                deltaY: try int16(delta.y)
            ))]
        case .leftClick:
            return [
                .mouseButton(MouseButtonPayload(button: .left, isDown: true)),
                .mouseButton(MouseButtonPayload(button: .left, isDown: false))
            ]
        case .rightClick:
            return [
                .mouseButton(MouseButtonPayload(button: .right, isDown: true)),
                .mouseButton(MouseButtonPayload(button: .right, isDown: false))
            ]
        case .doubleClick:
            return [.mouseDoubleClick(MouseDoubleClickPayload(button: .left))]
        case let .dragBegan(clickCount):
            return [.mouseButton(MouseButtonPayload(
                button: .left,
                isDown: true,
                clickCount: UInt8(clamping: clickCount)
            ))]
        case .dragEnded:
            return [.mouseButton(MouseButtonPayload(button: .left, isDown: false))]
        case .missionControl:
            return [.hotkey(HotkeyPayload(action: .missionControl))]
        case .appExpose:
            return [.hotkey(HotkeyPayload(action: .appExpose))]
        }
    }

    public static func payload(for output: RemoteInputEvent) throws -> MessagePayload {
        guard let first = try payloads(for: output).first else {
            throw TrackpadProtocolAdapterError.unsupportedOutput
        }
        return first
    }

    private static func int16(_ value: Double) throws -> Int16 {
        guard value.isFinite, value >= Double(Int16.min), value <= Double(Int16.max) else {
            throw TrackpadProtocolAdapterError.valueOutOfRange
        }
        return Int16(value.rounded())
    }
}

public enum SharedKeyboardProtocolAdapter {
    public static func payload(for output: KeyboardOutput) throws -> MessagePayload {
        switch output {
        case let .text(chunk):
            return .textInput(try TextInputPayload(text: chunk.value))
        case let .hotkey(hotkey):
            return .hotkey(HotkeyPayload(action: sharedHotkey(hotkey)))
        }
    }

    private static func sharedHotkey(_ hotkey: RemoteHotkey) -> HotkeyAction {
        switch hotkey {
        case .copy: return .copy
        case .paste: return .paste
        case .undo: return .undo
        case .redo: return .redo
        case .escape: return .escape
        case .return: return .returnKey
        case .tab: return .tab
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .deleteBackward: return .deleteBackward
        case .deleteWordBackward: return .deleteWordBackward
        case .selectLeft: return .selectLeft
        case .selectRight: return .selectRight
        case .selectUp: return .selectUp
        case .selectDown: return .selectDown
        }
    }
}
#endif
