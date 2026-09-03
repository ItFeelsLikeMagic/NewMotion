import Foundation

/// A framework-neutral representation of the events that the macOS adapter
/// may post.  Unit tests assert this stream; production uses CGEvent below.
public enum InjectedInputEvent: Equatable, Sendable {
    case pointer(delta: MacPointerDelta)
    case scroll(delta: MacScrollDelta)
    case mouseButton(button: MacMouseButton, isDown: Bool)
    case modifier(key: MacModifierKey, isDown: Bool)
    case unicodeText(String)
    case physicalKey(keyCode: UInt16, isDown: Bool)
}

public enum InputSinkError: Error, Equatable, Sendable {
    case accessibilityUnavailable
    case eventCreationFailed
    case eventPostFailed
    case injectedFailure
}

/// The only sink interface used by the safety controller.  It is intentionally
/// small and has no API for arbitrary key codes from the remote side.
public protocol InputEventSink: AnyObject {
    func send(_ event: InjectedInputEvent) throws
}

/// A deterministic sink for simulator/unit tests.  It never posts an event to
/// the real window server.
public final class MockInputEventSink: InputEventSink {
    public private(set) var events: [InjectedInputEvent] = []
    public var failureAtEventIndex: Int?

    public init(failureAtEventIndex: Int? = nil) {
        self.failureAtEventIndex = failureAtEventIndex
    }

    public func send(_ event: InjectedInputEvent) throws {
        if let failureAtEventIndex, events.count == failureAtEventIndex {
            throw InputSinkError.injectedFailure
        }
        events.append(event)
    }

    public func removeAll() {
        events.removeAll(keepingCapacity: true)
    }
}

public protocol AccessibilityTrustProviding: AnyObject {
    func isTrusted(prompt: Bool) -> Bool
}

/// Splits text into the UTF-16 runs posted per keyDown/keyUp pair.
public enum UnicodeKeyEvents {
    public static let maximumUnits = 4_096
    /// Some apps only honour the first 20 units of a keyboard event's string.
    public static let unitsPerEvent = 20

    public static func chunks(of value: String) -> [[UInt16]] {
        let units = Array(value.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + unitsPerEvent, units.count)
            // Never split a surrogate pair across events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }
}

#if os(macOS)
import ApplicationServices
import CoreGraphics

/// The permission adapter requests only the macOS Accessibility permission.
/// It does not request Input Monitoring, Screen Recording, Full Disk Access, or
/// administrator access.
public final class SystemAccessibilityTrust: AccessibilityTrustProviding {
    public init() {}

    public func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            // The documented value is a stable CFDictionary key.  Using the
            // literal avoids capturing ApplicationServices' mutable global
            // CFString under Swift 6 complete concurrency checking.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }
}

/// Production event sink backed by public Core Graphics APIs.  Every call
/// checks Accessibility again so revocation stops control immediately.
public final class CGEventInputSink: InputEventSink {
    private let trust: AccessibilityTrustProviding
    private let source: CGEventSource?

    public init(trust: AccessibilityTrustProviding = SystemAccessibilityTrust()) {
        self.trust = trust
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    public func send(_ event: InjectedInputEvent) throws {
        guard trust.isTrusted(prompt: false) else {
            throw InputSinkError.accessibilityUnavailable
        }

        switch event {
        case let .pointer(delta):
            let current = CGEvent(source: nil)?.location ?? .zero
            let next = CGPoint(x: current.x + delta.x, y: current.y + delta.y)
            guard let cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: next,
                mouseButton: .left
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
            cgEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
            cgEvent.post(tap: .cghidEventTap)

        case let .scroll(delta):
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clampedInt32(delta.y)),
                wheel2: Int32(clampedInt32(delta.x)),
                wheel3: 0
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.post(tap: .cghidEventTap)

        case let .mouseButton(button, isDown):
            let mouseButton: CGMouseButton = button == .left ? .left : .right
            let mouseType: CGEventType
            switch (mouseButton, isDown) {
            case (.left, true): mouseType = .leftMouseDown
            case (.left, false): mouseType = .leftMouseUp
            case (.right, true): mouseType = .rightMouseDown
            case (.right, false): mouseType = .rightMouseUp
            default: throw InputSinkError.eventCreationFailed
            }
            let location = CGEvent(source: nil)?.location ?? .zero
            guard let cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: mouseType,
                mouseCursorPosition: location,
                mouseButton: mouseButton
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.post(tap: .cghidEventTap)

        case let .modifier(key, isDown):
            guard let keyCode = Self.modifierKeyCodes[key],
                  let cgEvent = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: keyCode,
                    keyDown: isDown
                  ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.post(tap: .cghidEventTap)

        case let .physicalKey(keyCode, isDown):
            guard let cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(keyCode),
                keyDown: isDown
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.post(tap: .cghidEventTap)

        case let .unicodeText(value):
            try postUnicode(value)
        }
    }

    private func postUnicode(_ value: String) throws {
        guard value.utf16.count <= UnicodeKeyEvents.maximumUnits else { throw InputSinkError.eventCreationFailed }
        for var units in UnicodeKeyEvents.chunks(of: value) {
            guard let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else { throw InputSinkError.eventCreationFailed }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static let modifierKeyCodes: [MacModifierKey: CGKeyCode] = [
        .command: 55,
        .option: 58,
        .control: 59,
        .shift: 56,
        .function: 63
    ]

    private func clampedInt32(_ value: Double) -> Int32 {
        let rounded = value.rounded()
        return Int32(max(Double(Int32.min), min(Double(Int32.max), rounded)))
    }
}
#endif
