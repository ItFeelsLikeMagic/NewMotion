import Foundation

/// Rate-limits a stream of additive deltas to at most one delivery per
/// interval, summing everything that arrives in between.  The first delta of a
/// burst is delivered on the next hop so motion still starts promptly.
///
/// Deltas are produced on the main queue (touches) or on the Core Motion queue,
/// so the pending sum is lock-guarded.  Scheduled deliveries land on whatever
/// queue `execute` uses, which is the main queue in production.
final class DeltaCoalescer<Delta: Sendable>: @unchecked Sendable {
    var onFlush: ((Delta) -> Void)?
    var minimumInterval: TimeInterval
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var execute: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private let combine: (Delta, Delta) -> Delta
    private let lock = NSLock()
    private var pending: Delta?
    private var scheduled = false
    private var lastFlush: TimeInterval = -.infinity

    init(minimumInterval: TimeInterval, combine: @escaping (Delta, Delta) -> Delta) {
        self.minimumInterval = minimumInterval
        self.combine = combine
    }

    func send(_ delta: Delta) {
        lock.lock()
        pending = pending.map { combine($0, delta) } ?? delta
        let alreadyScheduled = scheduled
        scheduled = true
        lock.unlock()
        guard alreadyScheduled == false else { return }
        schedule(after: 0)
    }

    /// Delivers the pending sum immediately on the calling thread.  Callers use
    /// it to keep a discrete event ordered behind the motion that preceded it.
    func flushNow() {
        guard let value = take() else { return }
        onFlush?(value)
    }

    private func take() -> Delta? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = pending else { return nil }
        pending = nil
        lastFlush = now()
        return value
    }

    private func schedule(after delay: TimeInterval) {
        execute(delay) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let wait = minimumInterval - (now() - lastFlush)
        let hasPending = pending != nil
        lock.unlock()

        if hasPending, wait > 0 {
            schedule(after: wait)
            return
        }
        if let value = take() {
            onFlush?(value)
        }

        lock.lock()
        if pending == nil {
            scheduled = false
            lock.unlock()
        } else {
            let next = max(0, minimumInterval - (now() - lastFlush))
            lock.unlock()
            schedule(after: next)
        }
    }
}

extension DeltaCoalescer: MotionPointerOutputSink where Delta == MotionPointerDelta {
    /// Air-mouse samples arrive at the Core Motion rate; 40 ms is the air-mouse
    /// share of the same BLE link the trackpad uses.
    static func motionPointer() -> DeltaCoalescer<MotionPointerDelta> {
        DeltaCoalescer(minimumInterval: 0.04) {
            MotionPointerDelta(x: $0.x + $1.x, y: $0.y + $1.y)
        }
    }
}
