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
    public var displayCadenceLimitHz: Double
    public var tapMaximumDuration: TimeInterval
    public var tapMaximumTravel: Double
    public var doubleTapInterval: TimeInterval
    public var dragEnabled: Bool

    public init(
        pointerSensitivityX: Double = 1.0,
        pointerSensitivityY: Double = 1.0,
        scrollSensitivity: Double = 1.0,
        displayCadenceLimitHz: Double = 100,
        tapMaximumDuration: TimeInterval = 0.30,
        tapMaximumTravel: Double = 6,
        doubleTapInterval: TimeInterval = 0.35,
        dragEnabled: Bool = false
    ) {
        self.pointerSensitivityX = min(max(pointerSensitivityX, 0.05), 10)
        self.pointerSensitivityY = min(max(pointerSensitivityY, 0.05), 10)
        self.scrollSensitivity = min(max(scrollSensitivity, 0.05), 10)
        self.displayCadenceLimitHz = min(max(displayCadenceLimitHz, 1), 100)
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
    private var lastEmissionTime: TimeInterval?
    private var pendingPointer = TrackpadPoint.zero
    private var pendingScroll = TrackpadPoint.zero
    private var lastTapTime: TimeInterval?
    private var lastTapLocation: TrackpadPoint?
    private var gestureMoved = false

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
                outputs.append(contentsOf: emitPointer(scaledPointer(delta), at: timestamp))
            case .oneFinger where active.count == 1:
                outputs.append(contentsOf: emitPointer(scaledPointer(delta), at: timestamp))
            case .twoFinger where active.count >= 2:
                // Vertical scrolling is the only two-finger continuous
                // gesture in the MVP.  Horizontal movement is intentionally
                // discarded here.
                outputs.append(contentsOf: emitScroll(
                    TrackpadPoint(x: 0, y: delta.y * configuration.scrollSensitivity),
                    at: timestamp
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
            let wasTwoFinger = activeBefore.count >= 2 || modeBefore == .twoFinger
            let tap = isTap(activeBefore, ended: ended, at: timestamp)
            for touch in ended {
                active.removeValue(forKey: touch.id)
            }
            if isDragging {
                outputs.append(.dragEnded)
                isDragging = false
            } else if wasTwoFinger && active.isEmpty && tap {
                outputs.append(.rightClick)
                lastTapTime = nil
                lastTapLocation = nil
            } else if active.isEmpty && !wasTwoFinger && tap {
                outputs.append(.leftClick)
                lastTapTime = timestamp
                lastTapLocation = ended.first?.location
            }

            if active.isEmpty {
                resetTouches()
            } else if active.count >= 2 {
                mode = .twoFinger
                previousCentroid = centroid(of: active)
            } else {
                mode = .oneFinger
                previousCentroid = centroid(of: active)
            }
        }

        return outputs
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

    private mutating func emitPointer(_ delta: TrackpadPoint, at timestamp: TimeInterval) -> [TrackpadOutput] {
        guard delta.x != 0 || delta.y != 0 else { return [] }
        pendingPointer = pendingPointer + delta
        guard canEmit(at: timestamp) else { return [] }
        let output = TrackpadOutput.pointer(TrackpadPointerDelta(
            x: clamp(pendingPointer.x),
            y: clamp(pendingPointer.y)
        ))
        pendingPointer = .zero
        lastEmissionTime = timestamp
        return [output]
    }

    private mutating func emitScroll(_ delta: TrackpadPoint, at timestamp: TimeInterval) -> [TrackpadOutput] {
        guard delta.x != 0 || delta.y != 0 else { return [] }
        pendingScroll = pendingScroll + delta
        guard canEmit(at: timestamp) else { return [] }
        let output = TrackpadOutput.scroll(TrackpadScrollDelta(
            x: clamp(pendingScroll.x),
            y: clamp(pendingScroll.y)
        ))
        pendingScroll = .zero
        lastEmissionTime = timestamp
        return [output]
    }

    private func canEmit(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else { return false }
        guard let lastEmissionTime else { return true }
        return timestamp - lastEmissionTime >= 1 / configuration.displayCadenceLimitHz
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
