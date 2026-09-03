import Foundation

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
    case appBackgrounded
    case appForegrounded
}

public enum AudioCaptureAction: Equatable, Sendable {
    case startCapture
    case stopCapture
}

/// Pure push-to-talk state machine.  Capture starts only from the local
/// press event; there is no remote activation event by design.
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

        case .appForegrounded:
            appForegrounded = true
            return []
        }
    }
}

/// Regroups converted 16 kHz mono samples into fixed-size chunks.  40 ms per
/// chunk halves the per-frame header and crypto overhead on BLE compared to
/// the converter's native 20 ms buffers.
public struct PCM16Chunker: Sendable {
    public let samplesPerChunk: Int
    private var pending: [Int16] = []

    public init(samplesPerChunk: Int = 640) {
        self.samplesPerChunk = samplesPerChunk
        pending.reserveCapacity(samplesPerChunk)
    }

    public mutating func append(_ samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)
        var output: [[Int16]] = []
        while pending.count >= samplesPerChunk {
            output.append(Array(pending.prefix(samplesPerChunk)))
            pending.removeFirst(samplesPerChunk)
        }
        return output
    }

    public mutating func flush() -> [Int16]? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
