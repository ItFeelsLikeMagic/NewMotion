import Foundation

public struct CapturedPCM16Chunk: Equatable, Sendable {
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let samplePosition: UInt64
    public let sampleCount: UInt32
    public let pcmLittleEndian: Data
    public let level: Double

    public init?(
        sequence: UInt64,
        timestamp: TimeInterval,
        samplePosition: UInt64,
        sampleCount: UInt32,
        pcmLittleEndian: Data,
        level: Double
    ) {
        guard timestamp.isFinite,
              sampleCount > 0,
              pcmLittleEndian.count == Int(sampleCount) * 2,
              level.isFinite,
              level >= 0,
              level <= 1 else { return nil }
        self.sequence = sequence
        self.timestamp = timestamp
        self.samplePosition = samplePosition
        self.sampleCount = sampleCount
        self.pcmLittleEndian = pcmLittleEndian
        self.level = level
    }
}

public enum AudioCaptureState: String, Equatable, Sendable {
    case idle
    case capturing
}

public enum AudioCaptureEvent: Equatable, Sendable {
    case localPushToTalkPressed
    case localPushToTalkReleased
    case localCancel
    case interruptionBegan
    case routeChanged
    case permissionRevoked
    case appBackgrounded
    case appForegrounded
    case remoteActivationAttempt
}

public enum AudioCaptureAction: Equatable, Sendable {
    case startCapture
    case stopCapture
}

/// Pure push-to-talk state machine.  The remote side has no activation event;
/// `remoteActivationAttempt` is deliberately a no-op.
public struct AudioCaptureStateMachine: Sendable {
    public private(set) var state: AudioCaptureState = .idle
    public private(set) var appForegrounded = true
    public private(set) var permissionGranted = false

    public init(permissionGranted: Bool = false, appForegrounded: Bool = true) {
        self.permissionGranted = permissionGranted
        self.appForegrounded = appForegrounded
    }

    public mutating func setPermissionGranted(_ granted: Bool) -> [AudioCaptureAction] {
        permissionGranted = granted
        guard !granted, state == .capturing else { return [] }
        state = .idle
        return [.stopCapture]
    }

    @discardableResult
    public mutating func handle(_ event: AudioCaptureEvent) -> [AudioCaptureAction] {
        switch event {
        case .localPushToTalkPressed:
            guard appForegrounded, permissionGranted, state == .idle else { return [] }
            state = .capturing
            return [.startCapture]

        case .localPushToTalkReleased, .localCancel, .interruptionBegan, .routeChanged, .appBackgrounded:
            if event == .appBackgrounded { appForegrounded = false }
            guard state == .capturing else { return [] }
            state = .idle
            return [.stopCapture]

        case .permissionRevoked:
            permissionGranted = false
            guard state == .capturing else { return [] }
            state = .idle
            return [.stopCapture]

        case .appForegrounded:
            appForegrounded = true
            return []

        case .remoteActivationAttempt:
            return []
        }
    }
}

public struct AudioChunkerConfiguration: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let samplesPerChunk: Int

    public init(sampleRate: Int = 16_000, channels: Int = 1, samplesPerChunk: Int = 320) {
        self.sampleRate = max(1, sampleRate)
        self.channels = max(1, channels)
        self.samplesPerChunk = max(1, samplesPerChunk)
    }
}

/// Converts already-normalized mono Int16 samples into bounded wire chunks.
/// It deliberately contains no logging or persistence hooks.
public struct PCM16Chunker: Sendable {
    public let configuration: AudioChunkerConfiguration
    private var pending: [Int16] = []
    private var nextSequence: UInt64 = 0
    private var nextSamplePosition: UInt64 = 0
    private var pendingTimestamp: TimeInterval?

    public init(configuration: AudioChunkerConfiguration = AudioChunkerConfiguration()) {
        self.configuration = configuration
        pending.reserveCapacity(configuration.samplesPerChunk)
    }

    public mutating func append(samples: [Int16], timestamp: TimeInterval) -> [CapturedPCM16Chunk] {
        guard !samples.isEmpty, timestamp.isFinite else { return [] }
        if pendingTimestamp == nil { pendingTimestamp = timestamp }
        pending.append(contentsOf: samples)
        var output: [CapturedPCM16Chunk] = []
        while pending.count >= configuration.samplesPerChunk {
            let values = Array(pending.prefix(configuration.samplesPerChunk))
            pending.removeFirst(configuration.samplesPerChunk)
            let data = Self.encode(values)
            let level = Self.rmsLevel(values)
            if let chunk = CapturedPCM16Chunk(
                sequence: nextSequence,
                timestamp: pendingTimestamp ?? timestamp,
                samplePosition: nextSamplePosition,
                sampleCount: UInt32(values.count),
                pcmLittleEndian: data,
                level: level
            ) {
                output.append(chunk)
            }
            nextSequence += 1
            nextSamplePosition += UInt64(values.count)
            pendingTimestamp = pending.isEmpty ? nil : timestamp + Double(values.count) / Double(configuration.sampleRate)
        }
        return output
    }

    public mutating func flush() -> CapturedPCM16Chunk? {
        guard !pending.isEmpty else { return nil }
        let values = pending
        pending.removeAll(keepingCapacity: true)
        let data = Self.encode(values)
        let level = Self.rmsLevel(values)
        let timestamp = pendingTimestamp ?? 0
        let chunk = CapturedPCM16Chunk(
            sequence: nextSequence,
            timestamp: timestamp,
            samplePosition: nextSamplePosition,
            sampleCount: UInt32(values.count),
            pcmLittleEndian: data,
            level: level
        )
        pendingTimestamp = nil
        nextSequence += 1
        nextSamplePosition += UInt64(values.count)
        return chunk
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        pendingTimestamp = nil
        nextSequence = 0
        nextSamplePosition = 0
    }

    private static func encode(_ values: [Int16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func rmsLevel(_ values: [Int16]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0.0) { partial, value in
            let normalized = Double(value) / Double(Int16.max)
            return partial + normalized * normalized
        }
        return min(1, max(0, (sum / Double(values.count)).squareRoot()))
    }
}
