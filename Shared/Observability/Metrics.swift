/// Privacy-safe lifecycle and transport observability. Public methods accept
/// only protocol enums, counts, and timings; there is no API for text,
/// transcripts, audio bytes, QR material, or key material.

public enum LifecycleEvent: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case launched = 1
    case foregrounded = 2
    case backgrounded = 3
    case paused = 4
    case resumed = 5
    case terminated = 6
}

public enum MetricCounter: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case packetsSent = 1
    case packetsReceived = 2
    case sequenceGaps = 3
    case duplicates = 4
    case retries = 5
    case acknowledgements = 6
    case heartbeatReleases = 7
    case audioGaps = 8
    case motionSamples = 9
    case motionOutputs = 10
}

public enum MetricsEvent: Equatable, Sendable {
    case connectionState(TransportConnectionState)
    case packetSent(MessageType, byteCount: Int)
    case packetReceived(MessageType, byteCount: Int)
    case sequenceGap(MessageType, expected: UInt64, received: UInt64)
    case duplicate(MessageType)
    case retry(MessageType)
    case acknowledgement(MessageType, latencyMs: UInt64?)
    case latencySample(UInt64)
    case heartbeatRelease
    case audioGap
    case audioDuration(milliseconds: UInt64)
    case motionSample(rateHz: UInt16)
    case motionOutput(rateHz: UInt16)
    case lifecycle(LifecycleEvent)
}

public struct MetricsRecord: Equatable, Sendable {
    public let timestampMs: UInt64
    public let event: MetricsEvent

    public init(timestampMs: UInt64, event: MetricsEvent) {
        self.timestampMs = timestampMs
        self.event = event
    }
}

public protocol MetricsClock: AnyObject {
    var nowMs: UInt64 { get }
}

/// A manually advanced clock makes latency/counter tests independent of wall
/// clock scheduling.
public final class TestMetricsClock: MetricsClock {
    public private(set) var nowMs: UInt64

    public init(nowMs: UInt64 = 0) {
        self.nowMs = nowMs
    }

    public func advance(by milliseconds: UInt64) {
        nowMs &+= milliseconds
    }
}

public protocol MetricsSink: AnyObject {
    func append(_ record: MetricsRecord)
}

/// Test-only/local sink. It stores event metadata and never payload bytes.
public final class InMemoryMetricsSink: MetricsSink {
    public private(set) var records: [MetricsRecord] = []

    public init() {}

    public func append(_ record: MetricsRecord) {
        records.append(record)
    }

    public func removeAll() {
        records.removeAll(keepingCapacity: false)
    }
}

public struct MetricsSnapshot: Equatable, Sendable {
    public let counters: [MetricCounter: UInt64]
    public let packetsSentByType: [MessageType: UInt64]
    public let packetsReceivedByType: [MessageType: UInt64]
    public let latencyBuckets: [UInt64]
    public let latestLifecycle: LifecycleEvent?

    public init(
        counters: [MetricCounter: UInt64],
        packetsSentByType: [MessageType: UInt64],
        packetsReceivedByType: [MessageType: UInt64],
        latencyBuckets: [UInt64],
        latestLifecycle: LifecycleEvent?
    ) {
        self.counters = counters
        self.packetsSentByType = packetsSentByType
        self.packetsReceivedByType = packetsReceivedByType
        self.latencyBuckets = latencyBuckets
        self.latestLifecycle = latestLifecycle
    }
}

/// Local recorder with fixed latency buckets: 0–4, 5–9, 10–24, 25–49,
/// 50–99, 100–249, and 250+ ms. Buckets are stable for deterministic tests.
public final class MetricsRecorder {
    public static let latencyBucketUpperBounds: [UInt64] = [4, 9, 24, 49, 99, 249]

    private let clock: MetricsClock
    private let sink: MetricsSink?
    private var counters: [MetricCounter: UInt64] = [:]
    private var packetsSentByType: [MessageType: UInt64] = [:]
    private var packetsReceivedByType: [MessageType: UInt64] = [:]
    private var latencyBuckets = Array(repeating: UInt64(0), count: 7)
    private var latestLifecycle: LifecycleEvent?

    public init(clock: MetricsClock, sink: MetricsSink? = nil) {
        self.clock = clock
        self.sink = sink
    }

    public func recordConnectionState(_ state: TransportConnectionState) {
        emit(.connectionState(state))
    }

    public func recordPacketSent(type: MessageType, byteCount: Int) {
        increment(.packetsSent)
        packetsSentByType[type, default: 0] &+= 1
        emit(.packetSent(type, byteCount: max(0, byteCount)))
    }

    public func recordPacketReceived(type: MessageType, byteCount: Int) {
        increment(.packetsReceived)
        packetsReceivedByType[type, default: 0] &+= 1
        emit(.packetReceived(type, byteCount: max(0, byteCount)))
    }

    public func recordSequenceGap(type: MessageType, expected: UInt64, received: UInt64) {
        increment(.sequenceGaps)
        emit(.sequenceGap(type, expected: expected, received: received))
    }

    public func recordDuplicate(type: MessageType) {
        increment(.duplicates)
        emit(.duplicate(type))
    }

    public func recordRetry(type: MessageType) {
        increment(.retries)
        emit(.retry(type))
    }

    public func recordAcknowledgement(for type: MessageType, latencyMs: UInt64?) {
        increment(.acknowledgements)
        if let latencyMs { recordLatency(milliseconds: latencyMs) }
        emit(.acknowledgement(type, latencyMs: latencyMs))
    }

    public func recordLatency(milliseconds: UInt64) {
        let bucket: Int
        if let first = Self.latencyBucketUpperBounds.firstIndex(where: { milliseconds <= $0 }) {
            bucket = first
        } else {
            bucket = Self.latencyBucketUpperBounds.count
        }
        latencyBuckets[bucket] &+= 1
        emit(.latencySample(milliseconds))
    }

    public func recordHeartbeatRelease() {
        increment(.heartbeatReleases)
        emit(.heartbeatRelease)
    }

    public func recordAudioGap() {
        increment(.audioGaps)
        emit(.audioGap)
    }

    public func recordAudioDuration(milliseconds: UInt64) {
        emit(.audioDuration(milliseconds: milliseconds))
    }

    public func recordMotionSample(rateHz: UInt16) {
        increment(.motionSamples)
        emit(.motionSample(rateHz: rateHz))
    }

    public func recordMotionOutput(rateHz: UInt16) {
        increment(.motionOutputs)
        emit(.motionOutput(rateHz: rateHz))
    }

    public func recordLifecycle(_ event: LifecycleEvent) {
        latestLifecycle = event
        emit(.lifecycle(event))
    }

    public func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            counters: counters,
            packetsSentByType: packetsSentByType,
            packetsReceivedByType: packetsReceivedByType,
            latencyBuckets: latencyBuckets,
            latestLifecycle: latestLifecycle
        )
    }

    private func increment(_ counter: MetricCounter) {
        counters[counter, default: 0] &+= 1
    }

    private func emit(_ event: MetricsEvent) {
        sink?.append(MetricsRecord(timestampMs: clock.nowMs, event: event))
    }
}
