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

public struct TrackpadPointerDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TrackpadScrollDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum TrackpadOutput: Equatable, Sendable {
    case pointer(TrackpadPointerDelta)
    case scroll(TrackpadScrollDelta)
    case leftClick
    case rightClick
    case doubleClick
    case dragBegan
    case dragEnded
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
    public var dragEnabled: Bool

    public init(
        pointerSensitivityX: Double = 1.0,
        pointerSensitivityY: Double = 1.0,
        scrollSensitivity: Double = 1.0,
        tapMaximumDuration: TimeInterval = 0.30,
        tapMaximumTravel: Double = 6,
        doubleTapInterval: TimeInterval = 0.35,
        dragEnabled: Bool = false
    ) {
        self.pointerSensitivityX = min(max(pointerSensitivityX, 0.05), 10)
        self.pointerSensitivityY = min(max(pointerSensitivityY, 0.05), 10)
        self.scrollSensitivity = min(max(scrollSensitivity, 0.05), 10)
        self.tapMaximumDuration = min(max(tapMaximumDuration, 0.05), 1)
        self.tapMaximumTravel = min(max(tapMaximumTravel, 1), 100)
        self.doubleTapInterval = min(max(doubleTapInterval, 0.1), 1)
        self.dragEnabled = dragEnabled
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
        case twoFinger
        case dragging
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

    public init(configuration: TrackpadConfiguration = TrackpadConfiguration()) {
        self.configuration = configuration
    }

    public var activeTouchCount: Int { active.count }

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

    /// Drag is a separately guarded capability and defaults to disabled.  The
    /// caller should only enable it after forced-disconnect safety tests pass.
    public mutating func setDragEnabled(_ enabled: Bool) {
        configuration.dragEnabled = enabled
        if !enabled, isDragging {
            isDragging = false
            mode = active.isEmpty ? .idle : .oneFinger
        }
    }

    @discardableResult
    public mutating func handle(_ lifecycle: TrackpadLifecycle) -> [TrackpadOutput] {
        switch lifecycle {
        case .foreground:
            isForeground = true
            return []
        case .background, .cancel:
            if lifecycle == .background { isForeground = false }
            let result: [TrackpadOutput] = isDragging ? [.dragEnded] : []
            resetTouches()
            return result
        }
    }

    /// Processes a batch of changed touches.  The batch may contain one or
    /// more touches; unchanged touches remain in the internal active set.
    @discardableResult
    public mutating func handle(_ touches: [TrackpadTouch]) -> [TrackpadOutput] {
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

        var outputs: [TrackpadOutput] = []
        let beganCount = touches.filter { $0.phase == .began }.count
        if beganCount > 0 {
            if active.count == 1 {
                mode = shouldBeginDrag(at: timestamp) ? .dragging : .oneFinger
                previousCentroid = centroid(of: active)
                if mode == .dragging {
                    isDragging = true
                    outputs.append(.dragBegan)
                }
            } else if active.count >= 2 {
                // Adding a second finger must not jump the cursor/scroll
                // position.  Start a new centroid baseline.
                if isDragging {
                    isDragging = false
                    outputs.append(.dragEnded)
                }
                mode = .twoFinger
                previousCentroid = centroid(of: active)
                pendingPointer = .zero
            }
        }

        if touches.contains(where: { $0.phase == .moved }) {
            if modeBefore == .idle, mode == .idle {
                mode = active.count >= 2 ? .twoFinger : .oneFinger
            }
            let oldCentroid = previousCentroid ?? centroid(of: activeBefore)
            let newCentroid = centroid(of: active)
            let delta = newCentroid - oldCentroid
            previousCentroid = newCentroid
            if delta.magnitude > configuration.tapMaximumTravel {
                gestureMoved = true
            }

            switch mode {
            case .dragging:
                outputs.append(contentsOf: emitPointer(scaledPointer(delta)))
            case .oneFinger where active.count == 1:
                outputs.append(contentsOf: emitPointer(scaledPointer(delta)))
            case .twoFinger where active.count >= 2:
                // Vertical scrolling is the only two-finger continuous
                // gesture in the MVP.  Horizontal movement is intentionally
                // discarded here.
                outputs.append(contentsOf: emitScroll(
                    TrackpadPoint(x: 0, y: delta.y * configuration.scrollSensitivity)
                ))
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
            let multiFinger = gestureMaxTouches >= 2
            let tap = isTap(activeBefore, ended: ended, at: timestamp)
            for touch in ended {
                active.removeValue(forKey: touch.id)
            }
            if isDragging {
                outputs.append(.dragEnded)
                isDragging = false
            } else if multiFinger && active.isEmpty && tap {
                outputs.append(.rightClick)
                tapCount = 0
                lastTapTime = nil
                lastTapLocation = nil
            } else if active.isEmpty && !multiFinger && tap {
                let location = ended.first?.location
                tapCount = isChainedTap(at: timestamp, location: location) ? tapCount + 1 : 1
                if tapCount == 2 {
                    outputs.append(.doubleClick)
                } else {
                    if tapCount > 2 { tapCount = 1 }
                    outputs.append(.leftClick)
                }
                // The time and place are kept even for the double click, so a
                // press that follows it can still start a drag.
                lastTapTime = timestamp
                lastTapLocation = location
            }

            if active.isEmpty {
                resetTouches()
            } else {
                // A gesture that ever held two fingers stays a scroll until the
                // glass is clear.  Otherwise the finger left behind after an
                // uneven lift drags the cursor a few points.
                mode = (active.count >= 2 || gestureMaxTouches >= 2) ? .twoFinger : .oneFinger
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

    private func shouldBeginDrag(at timestamp: TimeInterval) -> Bool {
        guard configuration.dragEnabled,
              let lastTapTime,
              timestamp >= lastTapTime,
              timestamp - lastTapTime <= configuration.doubleTapInterval,
              let lastTapLocation,
              let first = active.values.first else { return false }
        return (first.current - lastTapLocation).magnitude <= configuration.tapMaximumTravel
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

    /// Emission is not rate limited here.  `TrackpadOutputCoalescer` is the
    /// single pacer for the link; a second gate on this side only delayed the
    /// tail of a gesture without saving a packet.
    private mutating func emitPointer(_ delta: TrackpadPoint) -> [TrackpadOutput] {
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
        return [.pointer(TrackpadPointerDelta(x: x, y: y))]
    }

    private mutating func emitScroll(_ delta: TrackpadPoint) -> [TrackpadOutput] {
        guard delta.x != 0 || delta.y != 0 else { return [] }
        pendingScroll = pendingScroll + delta
        let output = TrackpadOutput.scroll(TrackpadScrollDelta(
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
    }
}

public protocol TrackpadOutputSink: AnyObject {
    func send(_ output: TrackpadOutput)
}

/// Small adapter that lets the iPhone feature feed the shared pointer/scroll
/// protocol without putting protocol definitions in this UI module.
public final class TrackpadOutputForwarder: TrackpadOutputSink {
    public typealias Handler = (TrackpadOutput) -> Void
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ output: TrackpadOutput) {
        handler(output)
    }
}
