import Foundation

/// A rolling window of timings for one stage of the pipeline.
///
/// Recording is meant to sit on the cursor and voice paths, so it does the
/// least work that still answers the question: take a lock, write one slot,
/// bump an index. No allocation, no formatting, no sorting. The sorting
/// happens in `summary()`, which only a debug reader calls, about once a
/// second.
///
/// It keeps timings and counts only. Nothing about what was typed or said can
/// reach it, because it never sees a payload.
public final class LatencyTracker: @unchecked Sendable {
    /// About four seconds of cursor traffic at 60 a second, which is long
    /// enough to see a stall and short enough to forget one.
    public static let capacity = 256

    public let name: String

    private let lock = NSLock()
    private var samples = [UInt32](repeating: 0, count: LatencyTracker.capacity)
    private var count = 0
    private var next = 0
    /// Times the caller asked to record but could not, because the thing being
    /// measured never happened. A rising refusal rate is the earliest sign the
    /// link is falling behind.
    private var refusals: UInt64 = 0
    private var total: UInt64 = 0

    public init(name: String) {
        self.name = name
    }

    /// Record one timing, in microseconds. Microseconds rather than
    /// milliseconds because most of these stages are under a millisecond, and
    /// a stage that always reads zero teaches nothing.
    public func record(microseconds: UInt32) {
        lock.lock()
        samples[next] = microseconds
        next = (next + 1) % Self.capacity
        if count < Self.capacity { count += 1 }
        total &+= 1
        lock.unlock()
    }

    public func record(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return record(microseconds: 0) }
        record(microseconds: UInt32(min(seconds * 1_000_000, Double(UInt32.max))))
    }

    /// Count an attempt that did not get through: a send refused for want of
    /// room, a frame dropped, a read that failed.
    public func recordRefusal() {
        lock.lock()
        refusals &+= 1
        total &+= 1
        lock.unlock()
    }

    public func summary() -> LatencySummary? {
        lock.lock()
        let taken = Array(samples.prefix(count))
        let refused = refusals
        let attempts = total
        lock.unlock()
        guard !taken.isEmpty || refused > 0 else { return nil }
        let sorted = taken.sorted()
        return LatencySummary(
            name: name,
            samples: sorted.count,
            attempts: attempts,
            refusals: refused,
            medianMs: Self.milliseconds(sorted, quantile: 0.50),
            p95Ms: Self.milliseconds(sorted, quantile: 0.95),
            worstMs: sorted.last.map { Double($0) / 1000 } ?? 0
        )
    }

    public func reset() {
        lock.lock()
        count = 0
        next = 0
        refusals = 0
        total = 0
        lock.unlock()
    }

    /// Nearest-rank on an already sorted window.
    private static func milliseconds(_ sorted: [UInt32], quantile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((quantile * Double(sorted.count)).rounded(.up)) - 1
        return Double(sorted[min(max(rank, 0), sorted.count - 1)]) / 1000
    }
}

public struct LatencySummary: Equatable, Codable, Sendable {
    public let name: String
    /// How many timings the window holds.
    public let samples: Int
    /// Everything the stage was asked to do, including what it refused.
    public let attempts: UInt64
    public let refusals: UInt64
    public let medianMs: Double
    public let p95Ms: Double
    public let worstMs: Double

    public init(
        name: String,
        samples: Int,
        attempts: UInt64,
        refusals: UInt64,
        medianMs: Double,
        p95Ms: Double,
        worstMs: Double
    ) {
        self.name = name
        self.samples = samples
        self.attempts = attempts
        self.refusals = refusals
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.worstMs = worstMs
    }

    /// One line for a log or a debug page.
    public var line: String {
        String(
            format: "%@ n=%d p50=%.2fms p95=%.2fms max=%.2fms refused=%llu/%llu",
            name, samples, medianMs, p95Ms, worstMs, refusals, attempts
        )
    }
}

/// A monotonic stopwatch. Wall clock is wrong for this: it can step sideways
/// when the clock is corrected, and a negative duration in the middle of a
/// latency window is worse than no measurement.
public struct LatencyClock: Sendable {
    private let start: DispatchTime

    public init() {
        start = DispatchTime.now()
    }

    public var elapsedMicroseconds: UInt32 {
        let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return UInt32(min(nanos / 1_000, UInt64(UInt32.max)))
    }
}
