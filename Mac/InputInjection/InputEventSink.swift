import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// A framework-neutral representation of the events that the macOS adapter
/// may post.  Unit tests assert this stream; production uses CGEvent below.
public enum InjectedInputEvent: Equatable, Sendable {
    case pointer(delta: MacPointerDelta)
    case scroll(delta: MacScrollDelta)
    case mouseButton(button: MacMouseButton, isDown: Bool, clickCount: Int)
    case mouseDoubleClick(button: MacMouseButton)
    case modifier(key: MacModifierKey, isDown: Bool)
    case unicodeText(String)
    /// One allowlisted hotkey, whole.  The transitions travel together because
    /// the sink has to pace them, and a half-posted chord would strand a
    /// modifier.
    case hotkey([PhysicalKeyTransition])
    /// The same hotkey pressed `times` over.  It arrives as one event so the
    /// sink can post the whole run in a single burst.
    case hotkeyRun([PhysicalKeyTransition], times: Int)
}

public enum InputSinkError: Error, Equatable, Sendable {
    case accessibilityUnavailable
    case eventCreationFailed
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
    let isModifier: Bool
}

/// State that lives on the posting queue, plus the one number read back from
/// the main thread for the debug snapshot.
private final class KeyPostState: @unchecked Sendable {
    private let lock = NSLock()
    private var burstMilliseconds: Double?

    /// Only touched on the posting queue.
    var lastPostWasModifier = false
    /// Monotonic time of the last post, so a gap already served by an idle
    /// queue is not served again.
    var lastPostAt: TimeInterval?

    var lastBurstMilliseconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return burstMilliseconds
    }

    func record(burst: Double) {
        lock.lock()
        burstMilliseconds = burst
        lock.unlock()
    }
}

/// Keeps a synthetic cursor inside the displays it is actually on.
///
/// The window server pins the real cursor at the screen edge no matter what
/// position an event carries, but the event keeps the position it was built
/// with. A position past the edge is not inside the few-point strip the Dock
/// and the hot corners watch, so pushing into the bottom of the screen used to
/// pin the cursor there and still never reveal the Dock. A physical mouse
/// never produces one of these: its driver clamps first, and so does this.
private final class DisplayGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [CGRect] = []

    /// Clamps into the display `origin` sits on. A target that lands on some
    /// other display is left alone, so the cursor can still cross screens.
    func clamp(_ target: CGPoint, startingFrom origin: CGPoint) -> CGPoint {
        let bounds = rects(covering: origin)
        guard let home = bounds.first(where: { $0.contains(origin) }) else { return target }
        guard !bounds.contains(where: { $0.contains(target) }) else { return target }
        return CGPoint(
            x: min(max(target.x, home.minX), home.maxX - 1),
            y: min(max(target.y, home.minY), home.maxY - 1)
        )
    }

    /// Re-reads the arrangement only when the cursor turns up somewhere none
    /// of the cached displays cover, which is exactly when it went stale.
    private func rects(covering point: CGPoint) -> [CGRect] {
        lock.lock()
        defer { lock.unlock() }
        if !cached.contains(where: { $0.contains(point) }) {
            cached = Self.read()
        }
        return cached
    }

    private static func read() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
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

    /// Flags a real keyboard reports as part of the key itself rather than as
    /// a modifier the hand is holding.  The arrow keys carry both, and macOS
    /// records Mission Control's shortcut as Control+Function+Up, so an arrow
    /// event built without them never matches the system hotkey.
    private static let intrinsicFlagForKeyCode: [UInt16: CGEventFlags] = [
        123: [.maskSecondaryFn, .maskNumericPad],
        124: [.maskSecondaryFn, .maskNumericPad],
        125: [.maskSecondaryFn, .maskNumericPad],
        126: [.maskSecondaryFn, .maskNumericPad]
    ]

    /// A modifier goes out as a flags change rather than a key press, so the
    /// Dock can in principle read the Tab that follows before it has taken the
    /// Command in.  This is the gap that guards against that; at zero the two
    /// go out back to back, which is what a real keyboard chord looks like.
    private static let modifierSettle: TimeInterval = 0
    /// Ordinary keys only need to be distinguishable from each other.
    private static let keyGap: TimeInterval = 0.010
    /// Inside a run of one repeated key there is nothing to distinguish: the
    /// presses are identical by definition, and the window server neither
    /// coalesces them nor reads them as a key repeat, which is set by a flag on
    /// the event rather than worked out from timing.  Measured with
    /// `/keyburst`; see docs/latency.md.
    private static let keyRunGap: TimeInterval = 0

    private let trust: AccessibilityTrustProviding
    private let source: CGEventSource?
    private let queue = DispatchQueue(label: "phoneremote.input.hotkey")
    private let postState = KeyPostState()
    /// The distribution behind `lastKeyBurstMilliseconds`, which only ever
    /// holds the newest burst.
    private let keyPost: LatencyTracker?
    private let displays = DisplayGeometry()
    private var activeFlags: CGEventFlags = []
    /// The button this sink is holding down, and the click count its press
    /// carried.  Travel while a button is held has to go out as a drag rather
    /// than a move: a text view follows a selection by reading dragged events,
    /// and never sees a plain move at all.
    private var heldButton: (button: CGMouseButton, clickState: Int64)?

    public init(
        trust: AccessibilityTrustProviding = SystemAccessibilityTrust(),
        keyPost: LatencyTracker? = nil
    ) {
        self.trust = trust
        self.keyPost = keyPost
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// How long the last paced burst took from hand-off to its final event
    /// reaching the window server.  Read by the debug snapshot.
    public var lastKeyBurstMilliseconds: Double? { postState.lastBurstMilliseconds }

    public func send(_ event: InjectedInputEvent) throws {
        guard trust.isTrusted(prompt: false) else {
            throw InputSinkError.accessibilityUnavailable
        }

        switch event {
        case let .pointer(delta):
            let held = heldButton
            let current = CGEvent(source: nil)?.location ?? .zero
            // The delta fields keep the full requested travel even when the
            // position is pinned, the way a real mouse still reports a push
            // into the edge it cannot cross.
            let next = displays.clamp(
                CGPoint(x: current.x + delta.x, y: current.y + delta.y),
                startingFrom: current
            )
            guard let cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: Self.moveType(whileHolding: held?.button),
                mouseCursorPosition: next,
                mouseButton: held?.button ?? .left
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
            cgEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
            // The drag carries the press's click count for its whole length,
            // which is what keeps a word selection widening by word.
            if let held { cgEvent.setIntegerValueField(.mouseEventClickState, value: held.clickState) }
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

        case let .mouseButton(button, isDown, clickCount):
            let mouseButton: CGMouseButton = button == .left ? .left : .right
            let mouseType: CGEventType
            switch (mouseButton, isDown) {
            case (.left, true): mouseType = .leftMouseDown
            case (.left, false): mouseType = .leftMouseUp
            case (.right, true): mouseType = .rightMouseDown
            case (.right, false): mouseType = .rightMouseUp
            default: throw InputSinkError.eventCreationFailed
            }
            let clickState = Int64(min(max(clickCount, 1), 3))
            let location = CGEvent(source: nil)?.location ?? .zero
            guard let cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: mouseType,
                mouseCursorPosition: location,
                mouseButton: mouseButton
            ) else { throw InputSinkError.eventCreationFailed }
            cgEvent.setIntegerValueField(.mouseEventClickState, value: clickState)
            // Tracked before the post so a throw further up cannot leave the
            // sink believing it still holds a button it never pressed.
            heldButton = isDown ? (mouseButton, clickState) : nil
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

        case let .hotkeyRun(transitions, times):
            try postHotkey(transitions, times: times, gap: Self.keyRunGap)

        case let .unicodeText(value):
            try postUnicode(value)
        }
    }

    /// A held button turns travel into a drag.  Nothing held is an ordinary
    /// move, whatever button the event is nominally built with.
    private static func moveType(whileHolding button: CGMouseButton?) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        default: return .mouseMoved
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
        enqueue([PostableEvent(event: cgEvent, isModifier: modifier != nil)], paced: true)
    }

    /// Every event is built up front so a chord either posts whole or fails
    /// before anything reaches the window server.  Only the posting is spaced
    /// out, and never on the caller's thread, which is the main one.
    private func postHotkey(
        _ transitions: [PhysicalKeyTransition],
        times: Int = 1,
        gap: TimeInterval? = nil
    ) throws {
        var flags = activeFlags
        var events: [PostableEvent] = []
        for transition in Array(repeating: transitions, count: max(1, times)).flatMap({ $0 }) {
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
            events.append(PostableEvent(event: event, isModifier: modifier != nil))
        }

        enqueue(events, paced: true, gap: gap)
    }

    /// Every keyboard event goes through one serial queue, so a chord cannot
    /// overtake the modifier that has to precede it, and the pacing never runs
    /// on the caller's thread, which is the main one.
    private func enqueue(_ events: [PostableEvent], paced: Bool, gap: TimeInterval? = nil) {
        let state = postState
        let latency = keyPost
        let start = Date()
        queue.async {
            for item in events {
                // The gap separates one event from the one before it, so only
                // the part not already elapsed is worth waiting out.  A queue
                // that has been idle since the last press waits for nothing.
                if paced, let last = state.lastPostAt {
                    let wanted = gap ?? (state.lastPostWasModifier ? Self.modifierSettle : Self.keyGap)
                    let remaining = wanted - (ProcessInfo.processInfo.systemUptime - last)
                    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                }
                item.event.post(tap: .cghidEventTap)
                state.lastPostWasModifier = item.isModifier
                state.lastPostAt = ProcessInfo.processInfo.systemUptime
            }
            let elapsed = Date().timeIntervalSince(start)
            state.record(burst: elapsed * 1_000)
            latency?.record(seconds: elapsed)
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
        event.flags = flags.union(Self.intrinsicFlagForKeyCode[keyCode] ?? [])
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
        var events: [PostableEvent] = []
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
            events.append(PostableEvent(event: down, isModifier: false))
            events.append(PostableEvent(event: up, isModifier: false))
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
