import Foundation

public struct TrackpadPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    fileprivate static let zero = TrackpadPoint(x: 0, y: 0)

    fileprivate static func + (lhs: TrackpadPoint, rhs: TrackpadPoint) -> TrackpadPoint {
        TrackpadPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    fileprivate static func - (lhs: TrackpadPoint, rhs: TrackpadPoint) -> TrackpadPoint {
        TrackpadPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    fileprivate static func / (lhs: TrackpadPoint, rhs: Double) -> TrackpadPoint {
        TrackpadPoint(x: lhs.x / rhs, y: lhs.y / rhs)
    }

    fileprivate static func * (lhs: TrackpadPoint, rhs: Double) -> TrackpadPoint {
        TrackpadPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    fileprivate var magnitude: Double { (x * x + y * y).squareRoot() }
}

public enum TrackpadTouchPhase: String, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

public struct TrackpadTouch: Equatable, Sendable {
    public let id: UInt64
    public let location: TrackpadPoint
    public let phase: TrackpadTouchPhase
    public let timestamp: TimeInterval

    public init(id: UInt64, location: TrackpadPoint, phase: TrackpadTouchPhase, timestamp: TimeInterval) {
        self.id = id
        self.location = location
        self.phase = phase
        self.timestamp = timestamp
    }
}

public struct CursorDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScrollDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum RemoteInputEvent: Equatable, Sendable {
    case pointer(CursorDelta)
    case scroll(ScrollDelta)
    case leftClick
    case rightClick
    case doubleClick
    /// The press that starts a drag. `clickCount` is which click of a run it
    /// continues: two extends a text selection by word, three by line.
    case dragBegan(clickCount: Int)
    case dragEnded
    case missionControl
    case appExpose
}

public enum TrackpadLifecycle: Equatable, Sendable {
    case foreground
    case background
    case cancel
}

public struct TrackpadConfiguration: Equatable, Sendable {
    public var pointerSensitivityX: Double
    public var pointerSensitivityY: Double
    public var scrollSensitivity: Double
    public var tapMaximumDuration: TimeInterval
    public var tapMaximumTravel: Double
    public var doubleTapInterval: TimeInterval
    /// How long the button stays down after the finger leaves during a drag.
    /// The glass is small, so a long selection needs more than one pass; a
    /// finger back down inside this window carries on where it left off.
    public var dragLiftGrace: TimeInterval
    /// How far three fingers must travel up before the swipe counts.
    public var threeFingerSwipeTravel: Double
    /// Points in from each side where one finger scrolls instead of moving the
    /// cursor.  A thumb's width, so the strips are findable without looking and
    /// still leave most of the glass for the cursor.  Zero turns them off.
    public var edgeScrollWidth: Double

    public init(
        pointerSensitivityX: Double = 1.0,
        pointerSensitivityY: Double = 1.0,
        scrollSensitivity: Double = 1.0,
        tapMaximumDuration: TimeInterval = 0.30,
        tapMaximumTravel: Double = 6,
        doubleTapInterval: TimeInterval = 0.35,
        dragLiftGrace: TimeInterval = 0.25,
        threeFingerSwipeTravel: Double = 45,
        edgeScrollWidth: Double = 44
    ) {
        self.pointerSensitivityX = min(max(pointerSensitivityX, 0.05), 10)
        self.pointerSensitivityY = min(max(pointerSensitivityY, 0.05), 10)
        self.scrollSensitivity = min(max(scrollSensitivity, 0.05), 10)
        self.tapMaximumDuration = min(max(tapMaximumDuration, 0.05), 1)
        self.tapMaximumTravel = min(max(tapMaximumTravel, 1), 100)
        self.doubleTapInterval = min(max(doubleTapInterval, 0.1), 1)
        self.dragLiftGrace = min(max(dragLiftGrace, 0), 1)
        self.threeFingerSwipeTravel = min(max(threeFingerSwipeTravel, 10), 400)
        self.edgeScrollWidth = min(max(edgeScrollWidth, 0), 200)
    }
}

/// Pure touch gesture state machine.  UIKit is intentionally kept out of this
/// file so simulator and deterministic transport tests can exercise it.
public struct TrackpadGestureEngine: Sendable {
    private struct ActiveTouch: Sendable {
        var start: TrackpadPoint
        var current: TrackpadPoint
        var beganAt: TimeInterval
    }

    private enum Mode: Sendable {
        case idle
        case oneFinger
        /// One finger scrolling: it either landed in an edge strip or rested
        /// One finger that started inside an edge strip.
        case oneFingerScroll
        case twoFinger
        case threeFinger
        /// A press that chained onto the tap before it.  Nothing has been sent
        /// yet: it is still a double click until it travels far enough to be a
        /// drag instead.
        case dragArmed
        case dragging
        /// The finger left mid-drag and the button is still down, waiting out
        /// `dragLiftGrace` for it to come back.
        case dragSuspended
    }

    public private(set) var configuration: TrackpadConfiguration
    public private(set) var isForeground: Bool = true
    public private(set) var isDragging: Bool = false

    private var active: [UInt64: ActiveTouch] = [:]
    private var mode: Mode = .idle
    private var previousCentroid: TrackpadPoint?
    private var pendingPointer = TrackpadPoint.zero
    private var pendingScroll = TrackpadPoint.zero
    private var lastTapTime: TimeInterval?
    private var lastTapLocation: TrackpadPoint?
    /// Taps chained inside `doubleTapInterval`.  The second one is the double
    /// click; a third starts counting again instead of chaining forever.
    private var tapCount = 0
    private var gestureMoved = false
    /// Two fingers rarely leave the glass in the same touch batch.  Remembering
    /// the widest the gesture ever got keeps a staggered lift a right click
    /// instead of the left click the remaining finger would look like.
    private var gestureMaxTouches = 0
    /// Three-finger travel since the third finger landed, and whether this
    /// gesture already fired.  One swipe is one Mission Control, however far
    /// the hand keeps going afterwards.
    private var threeFingerTravel = TrackpadPoint.zero
    private var threeFingerFired = false
    /// Which click of a run an armed or running drag continues.
    private var dragClickCount = 2
    /// When the finger left mid-drag, while the button is still down.
    private var dragSuspendedAt: TimeInterval?
    /// The edge strips are a fraction of the surface, so the engine has to be
    /// told how wide the glass under it is.
    private var surfaceWidth: Double = 0

    public init(configuration: TrackpadConfiguration = TrackpadConfiguration()) {
        self.configuration = configuration
    }

    public var activeTouchCount: Int { active.count }

    /// True while one finger is scrolling.  Other sensors feeding the same
    /// cursor read this to send their travel as scroll too, which is what lets
    /// a held finger turn the air mouse into a scroll wheel.
    public var isOneFingerScrolling: Bool { mode == .oneFingerScroll }

    /// True while a drag is holding the button down with no finger on the
    /// glass.  The caller drives `flushSuspendedDrag(at:)` on a timer for as
    /// long as this is set: nothing else will arrive to end the drag.
    public var isDragSuspended: Bool { mode == .dragSuspended }

    public mutating func setSurfaceWidth(_ width: Double) {
        surfaceWidth = width.isFinite && width > 0 ? width : 0
    }

    public mutating func setSensitivity(pointerX: Double? = nil, pointerY: Double? = nil, scroll: Double? = nil) {
        if let pointerX {
            configuration.pointerSensitivityX = min(max(pointerX, 0.05), 10)
        }
        if let pointerY {
            configuration.pointerSensitivityY = min(max(pointerY, 0.05), 10)
        }
        if let scroll {
            configuration.scrollSensitivity = min(max(scroll, 0.05), 10)
        }
    }

    /// Ends a suspended drag once the grace window has run out.  Safe to call
    /// at any time: it is quiet unless a drag is actually waiting.
    @discardableResult
    public mutating func flushSuspendedDrag(at timestamp: TimeInterval) -> [RemoteInputEvent] {
        guard mode == .dragSuspended, let dragSuspendedAt,
              timestamp - dragSuspendedAt >= configuration.dragLiftGrace else { return [] }
        resetTouches()
        return [.dragEnded]
    }

    @discardableResult
    public mutating func handle(_ lifecycle: TrackpadLifecycle) -> [RemoteInputEvent] {
        switch lifecycle {
        case .foreground:
            isForeground = true
            return []
        case .background, .cancel:
            if lifecycle == .background { isForeground = false }
            let result: [RemoteInputEvent] = isDragging ? [.dragEnded] : []
            resetTouches()
            return result
        }
    }

    /// Processes a batch of changed touches.  The batch may contain one or
    /// more touches; unchanged touches remain in the internal active set.
    @discardableResult
    public mutating func handle(_ touches: [TrackpadTouch]) -> [RemoteInputEvent] {
        guard isForeground, !touches.isEmpty else { return [] }
        let timestamp = touches.map(\.timestamp).max() ?? 0
        let activeBefore = active
        let modeBefore = mode

        for touch in touches {
            switch touch.phase {
            case .began:
                active[touch.id] = ActiveTouch(
                    start: touch.location,
                    current: touch.location,
                    beganAt: touch.timestamp
                )
            case .moved:
                if var item = active[touch.id] {
                    item.current = touch.location
                    active[touch.id] = item
                }
            case .ended, .cancelled:
                if var item = active[touch.id] {
                    item.current = touch.location
                    active[touch.id] = item
                }
            }
        }

        gestureMaxTouches = max(gestureMaxTouches, active.count)

        var outputs: [RemoteInputEvent] = []
        let beganCount = touches.filter { $0.phase == .began }.count
        if beganCount > 0 {
            if active.count == 1 {
                if resumesSuspendedDrag(at: timestamp) {
                    // The button never came up, so this is the same drag: no
                    // new press, only a fresh baseline to measure from.
                    mode = .dragging
                    dragSuspendedAt = nil
                } else if isChainedTap(at: timestamp, location: active.values.first?.current) {
                    // Chaining onto the tap before it is the whole guard on a
                    // drag.  What it is stays ambiguous: a quick lift makes it
                    // the second click, travel makes it the press of a drag.
                    mode = .dragArmed
                    dragClickCount = min(tapCount + 1, 3)
                } else if isInsideEdgeStrip(active.values.first?.start) {
                    mode = .oneFingerScroll
                } else {
                    mode = .oneFinger
                }
                previousCentroid = centroid(of: active)
            } else if active.count >= 2 {
                // Adding a finger must not jump the cursor/scroll position.
                // Start a new centroid baseline.
                if isDragging {
                    isDragging = false
                    dragSuspendedAt = nil
                    outputs.append(.dragEnded)
                }
                mode = active.count >= 3 ? .threeFinger : .twoFinger
                previousCentroid = centroid(of: active)
                pendingPointer = .zero
                if mode == .threeFinger {
                    pendingScroll = .zero
                    threeFingerTravel = .zero
                }
            }
        }

        if touches.contains(where: { $0.phase == .moved }) {
            if modeBefore == .idle, mode == .idle {
                switch active.count {
                case 0, 1: mode = .oneFinger
                case 2: mode = .twoFinger
                default: mode = .threeFinger
                }
            }
            let oldCentroid = previousCentroid ?? centroid(of: activeBefore)
            let newCentroid = centroid(of: active)
            let delta = newCentroid - oldCentroid
            previousCentroid = newCentroid
            if delta.magnitude > configuration.tapMaximumTravel {
                gestureMoved = true
            }

            switch mode {
            case .dragArmed where active.count == 1:
                outputs.append(contentsOf: promoteArmedDrag())
            case .dragging:
                outputs.append(contentsOf: emitPointer(scaledPointer(delta)))
            case .oneFinger where active.count == 1:
                outputs.append(contentsOf: emitPointer(scaledPointer(delta)))
            case .oneFingerScroll where active.count == 1:
                outputs.append(contentsOf: emitScroll(
                    TrackpadPoint(x: 0, y: delta.y * configuration.scrollSensitivity)
                ))
            case .twoFinger where active.count >= 2:
                // Vertical scrolling is the only two-finger continuous
                // gesture in the MVP.  Horizontal movement is intentionally
                // discarded here.
                outputs.append(contentsOf: emitScroll(
                    TrackpadPoint(x: 0, y: delta.y * configuration.scrollSensitivity)
                ))
            case .threeFinger:
                // Raw travel, not scaled: the threshold is a distance on the
                // glass, not a cursor speed.
                outputs.append(contentsOf: emitThreeFingerSwipe(delta))
            default:
                break
            }
        }

        let ended = touches.filter { $0.phase == .ended }
        let cancelled = touches.contains(where: { $0.phase == .cancelled })
        if cancelled {
            if isDragging { outputs.append(.dragEnded) }
            resetTouches()
            return outputs
        }

        if !ended.isEmpty {
            let tap = isTap(activeBefore, ended: ended, at: timestamp)
            for touch in ended {
                active.removeValue(forKey: touch.id)
            }
            if isDragging {
                if active.isEmpty {
                    // The glass is small, so one pass rarely covers a whole
                    // selection.  The button stays down for the grace window
                    // and a finger back down inside it carries on.
                    mode = .dragSuspended
                    dragSuspendedAt = timestamp
                    previousCentroid = nil
                    pendingPointer = .zero
                    return outputs
                }
                outputs.append(.dragEnded)
                isDragging = false
            } else if active.isEmpty && tap {
                // The gesture's widest moment picks the click.  Three fingers
                // are not a click at all, so they make no event rather than
                // falling through to the one-finger case.
                switch gestureMaxTouches {
                case 0, 1:
                    let location = ended.first?.location
                    tapCount = isChainedTap(at: timestamp, location: location) ? tapCount + 1 : 1
                    if tapCount == 2 {
                        outputs.append(.doubleClick)
                    } else {
                        if tapCount > 2 { tapCount = 1 }
                        outputs.append(.leftClick)
                    }
                    // The time and place are kept even for the double click,
                    // so a press that follows it can still start a drag.
                    lastTapTime = timestamp
                    lastTapLocation = location
                case 2:
                    outputs.append(.rightClick)
                    tapCount = 0
                    lastTapTime = nil
                    lastTapLocation = nil
                default:
                    tapCount = 0
                    lastTapTime = nil
                    lastTapLocation = nil
                }
            }

            if active.isEmpty {
                resetTouches()
            } else {
                // A gesture stays in the mode its widest moment earned until
                // the glass is clear.  Otherwise the finger left behind after
                // an uneven lift drags the cursor a few points.
                if max(active.count, gestureMaxTouches) >= 3 {
                    mode = .threeFinger
                } else if max(active.count, gestureMaxTouches) >= 2 {
                    mode = .twoFinger
                } else {
                    mode = .oneFinger
                }
                previousCentroid = centroid(of: active)
            }
        }

        return outputs
    }

    /// True when this tap lands close enough, soon enough, to continue the run
    /// of taps that came before it.
    private func isChainedTap(at timestamp: TimeInterval, location: TrackpadPoint?) -> Bool {
        guard let lastTapTime,
              timestamp >= lastTapTime,
              timestamp - lastTapTime <= configuration.doubleTapInterval,
              let lastTapLocation,
              let location else { return false }
        return (location - lastTapLocation).magnitude <= configuration.tapMaximumTravel
    }

    private func resumesSuspendedDrag(at timestamp: TimeInterval) -> Bool {
        guard mode == .dragSuspended, let dragSuspendedAt, timestamp >= dragSuspendedAt else { return false }
        return timestamp - dragSuspendedAt < configuration.dragLiftGrace
    }

    /// Turns an armed press into a drag once it has travelled far enough to
    /// stop looking like the second half of a double tap.  The travel since
    /// the press belongs to the drag, so it goes out with it rather than
    /// being spent on deciding.
    private mutating func promoteArmedDrag() -> [RemoteInputEvent] {
        guard let touch = active.values.first else { return [] }
        let travel = touch.current - touch.start
        guard travel.magnitude > configuration.tapMaximumTravel else { return [] }
        mode = .dragging
        isDragging = true
        // The press replaces the click this tap would have sent, so the run
        // must not chain any further.
        tapCount = 0
        lastTapTime = nil
        lastTapLocation = nil
        return [.dragBegan(clickCount: dragClickCount)] + emitPointer(scaledPointer(travel))
    }

    private func isTap(
        _ activeBefore: [UInt64: ActiveTouch],
        ended: [TrackpadTouch],
        at timestamp: TimeInterval
    ) -> Bool {
        guard !activeBefore.isEmpty, !gestureMoved else { return false }
        let endedByID = Dictionary(uniqueKeysWithValues: ended.map { ($0.id, $0) })
        return activeBefore.allSatisfy { id, item in
            let end = endedByID[id]?.location ?? item.current
            let duration = max(0, timestamp - item.beganAt)
            return duration <= configuration.tapMaximumDuration &&
                (end - item.start).magnitude <= configuration.tapMaximumTravel
        }
    }

    /// Both strips together must leave a usable middle, so a width set wider
    /// than the glass can hold turns the strips off rather than swallowing it.
    private func isInsideEdgeStrip(_ point: TrackpadPoint?) -> Bool {
        guard let point, configuration.edgeScrollWidth > 0, surfaceWidth > 0,
              configuration.edgeScrollWidth * 3 <= surfaceWidth else { return false }
        return point.x <= configuration.edgeScrollWidth
            || point.x >= surfaceWidth - configuration.edgeScrollWidth
    }

    private func centroid(of values: [UInt64: ActiveTouch]) -> TrackpadPoint {
        guard !values.isEmpty else { return .zero }
        let sum = values.values.reduce(into: TrackpadPoint.zero) { $0 = $0 + $1.current }
        return sum / Double(values.count)
    }

    private func scaledPointer(_ delta: TrackpadPoint) -> TrackpadPoint {
        TrackpadPoint(
            x: delta.x * configuration.pointerSensitivityX,
            y: delta.y * configuration.pointerSensitivityY
        )
    }

    /// Emission is not rate limited here.  `CursorMixer` is the
    /// single pacer for the link; a second gate on this side only delayed the
    /// tail of a gesture without saving a packet.
    private mutating func emitPointer(_ delta: TrackpadPoint) -> [RemoteInputEvent] {
        guard delta.x != 0 || delta.y != 0 else { return [] }
        pendingPointer = pendingPointer + delta
        // The wire carries whole points, so quantize here and keep the
        // remainder for the next packet.  Rounding each packet independently
        // discards a slow 0.3 point/sample drag entirely instead of moving it
        // 3 points every ten packets.  `resetTouches` clears the carry on lift.
        let x = clamp(pendingPointer.x).rounded()
        let y = clamp(pendingPointer.y).rounded()
        guard x != 0 || y != 0 else { return [] }
        pendingPointer = TrackpadPoint(x: pendingPointer.x - x, y: pendingPointer.y - y)
        return [.pointer(CursorDelta(x: x, y: y))]
    }

    /// Up opens Mission Control, down opens the app's windows, matching a Mac
    /// trackpad.  The dominance check keeps a sideways three-finger swipe,
    /// which means something else on a Mac, from claiming either one.
    private mutating func emitThreeFingerSwipe(_ delta: TrackpadPoint) -> [RemoteInputEvent] {
        guard !threeFingerFired else { return [] }
        threeFingerTravel = threeFingerTravel + delta
        let vertical = threeFingerTravel.y
        guard abs(vertical) >= configuration.threeFingerSwipeTravel,
              abs(vertical) > abs(threeFingerTravel.x) else { return [] }
        threeFingerFired = true
        // Up is negative on the glass.
        return [vertical < 0 ? .missionControl : .appExpose]
    }

    private mutating func emitScroll(_ delta: TrackpadPoint) -> [RemoteInputEvent] {
        guard delta.x != 0 || delta.y != 0 else { return [] }
        pendingScroll = pendingScroll + delta
        let output = RemoteInputEvent.scroll(ScrollDelta(
            x: clamp(pendingScroll.x),
            y: clamp(pendingScroll.y)
        ))
        pendingScroll = .zero
        return [output]
    }

    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -10_000), 10_000)
    }

    private mutating func resetTouches() {
        active.removeAll(keepingCapacity: true)
        mode = .idle
        previousCentroid = nil
        pendingPointer = .zero
        pendingScroll = .zero
        isDragging = false
        gestureMoved = false
        gestureMaxTouches = 0
        threeFingerTravel = .zero
        threeFingerFired = false
        dragSuspendedAt = nil
    }
}

public protocol RemoteInputEventSink: AnyObject {
    func send(_ output: RemoteInputEvent)
}

/// Small adapter that lets the iPhone feature feed the shared pointer/scroll
/// protocol without putting protocol definitions in this UI module.
public final class RemoteInputEventForwarder: RemoteInputEventSink {
    public typealias Handler = (RemoteInputEvent) -> Void
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ output: RemoteInputEvent) {
        handler(output)
    }
}
