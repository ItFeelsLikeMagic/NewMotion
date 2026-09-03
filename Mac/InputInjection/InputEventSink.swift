import Foundation

/// A framework-neutral representation of the events that the macOS adapter
/// may post.  Unit tests assert this stream; production uses CGEvent below.
public enum InjectedInputEvent: Equatable, Sendable {
    case pointer(delta: MacPointerDelta)
    case scroll(delta: MacScrollDelta)
    case mouseButton(button: MacMouseButton, isDown: Bool)
    case mouseDoubleClick(button: MacMouseButton)
    case modifier(key: MacModifierKey, isDown: Bool)
    case unicodeText(String)
    /// One allowlisted hotkey, whole.  The transitions travel together because
    /// the sink has to pace them, and a half-posted chord would strand a
    /// modifier.
    case hotkey([PhysicalKeyTransition])
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

/// CGEvent is not Sendable, but a built event is only read by the queue that
/// posts it, so it crosses that one hop by hand.
private struct PostableEvent: @unchecked Sendable {
    let event: CGEvent

    init(_ event: CGEvent) {
        self.event = event
    }
}

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
    /// The key codes that carry a modifier flag.  A synthetic key event does
    /// not inherit the flag from a synthetic modifier press, so the sink tracks
    /// what it is holding and stamps every key event with it.  Without this,
    /// Command+Tab arrives at the Dock as a bare Tab.
    private static let flagForKeyCode: [UInt16: CGEventFlags] = [
        55: .maskCommand,
        56: .maskShift,
        58: .maskAlternate,
        59: .maskControl,
        63: .maskSecondaryFn
    ]

    /// The Dock only opens the app switcher when it sees Command go down, then
    /// Tab, then Command come back up as separate moments.  A burst posted in
    /// one instant is ignored, so key events are spaced out.
    private static let keyGap: TimeInterval = 0.04

    private let trust: AccessibilityTrustProviding
    private let source: CGEventSource?
    private let queue = DispatchQueue(label: "phoneremote.input.hotkey")
    private var activeFlags: CGEventFlags = []

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

        case let .mouseDoubleClick(button):
            try postDoubleClick(button)

        case let .modifier(key, isDown):
            guard let keyCode = Self.modifierKeyCodes[key] else {
                throw InputSinkError.eventCreationFailed
            }
            try postKey(keyCode: UInt16(keyCode), isDown: isDown)

        case let .hotkey(transitions):
            try postHotkey(transitions)

        case let .unicodeText(value):
            try postUnicode(value)
        }
    }

    private func postKey(keyCode: UInt16, isDown: Bool) throws {
        let modifier = Self.flagForKeyCode[keyCode]
        if let modifier {
            if isDown {
                activeFlags.insert(modifier)
            } else {
                activeFlags.remove(modifier)
            }
        }
        guard let cgEvent = build(keyCode: keyCode, isDown: isDown, flags: activeFlags, isModifier: modifier != nil) else {
            throw InputSinkError.eventCreationFailed
        }
        enqueue([cgEvent], paced: true)
    }

    /// Every event is built up front so a chord either posts whole or fails
    /// before anything reaches the window server.  Only the posting is spaced
    /// out, and never on the caller's thread, which is the main one.
    private func postHotkey(_ transitions: [PhysicalKeyTransition]) throws {
        var flags = activeFlags
        var events: [CGEvent] = []
        for transition in transitions {
            let modifier = Self.flagForKeyCode[transition.keyCode]
            if let modifier {
                if transition.isDown {
                    flags.insert(modifier)
                } else {
                    flags.remove(modifier)
                }
            }
            guard let event = build(
                keyCode: transition.keyCode,
                isDown: transition.isDown,
                flags: flags,
                isModifier: modifier != nil
            ) else { throw InputSinkError.eventCreationFailed }
            events.append(event)
        }

        enqueue(events, paced: true)
    }

    /// Every keyboard event goes through one serial queue, so a chord cannot
    /// overtake the modifier that has to precede it, and the pacing never runs
    /// on the caller's thread, which is the main one.
    private func enqueue(_ events: [CGEvent], paced: Bool) {
        let carried = events.map(PostableEvent.init)
        let gap = paced ? Self.keyGap : 0
        queue.async {
            for item in carried {
                if gap > 0 { Thread.sleep(forTimeInterval: gap) }
                item.event.post(tap: .cghidEventTap)
            }
        }
    }

    /// A modifier reports itself as a flags change, not as a key press, which
    /// is what the Dock watches when it decides whether Command is down during
    /// a Tab.  Ordinary keys carry the flags a real keyboard would.
    private func build(keyCode: UInt16, isDown: Bool, flags: CGEventFlags, isModifier: Bool) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: isDown
        ) else { return nil }
        if isModifier { event.type = .flagsChanged }
        event.flags = flags
        return event
    }

    /// A double click is a press and release whose click state is 2. Apps read
    /// that count rather than the gap between two separate clicks, so this
    /// survives the link latency that would break a replayed pair.
    private func postDoubleClick(_ button: MacMouseButton) throws {
        let mouseButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [downType, upType] {
            guard let cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: mouseButton
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.setIntegerValueField(.mouseEventClickState, value: 2)
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ value: String) throws {
        guard value.utf16.count <= UnicodeKeyEvents.maximumUnits else { throw InputSinkError.eventCreationFailed }
        var events: [CGEvent] = []
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
            events.append(down)
            events.append(up)
        }
        // Typed text needs no spacing, but it shares the queue so a Return
        // pressed before it cannot arrive after it.
        enqueue(events, paced: false)
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
