import Foundation

public enum BLEFramingError: Error, Equatable, Sendable {
    case emptyPayload
    case valueLengthTooSmall
    case valueLengthTooLarge
    case envelopeTooLarge
    case tooManyFragments
    case malformedHeader
    case unsupportedVersion
    case unknownFrameKind
    case invalidFlags
    case invalidLength
    case invalidFragmentIndex
    case duplicateMessage
    case outOfOrderFragment
    case conflictingFragment
    case queueFull
    case reliableWindowFull
}

public enum BLEFrameKind: UInt8, Sendable {
    case data = 1
    case control = 2
}

public struct BLEFrameFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let reliable = BLEFrameFlags(rawValue: 1 << 0)
    public static let first = BLEFrameFlags(rawValue: 1 << 1)
    public static let last = BLEFrameFlags(rawValue: 1 << 2)
    public static let validBits: UInt8 = reliable.rawValue | first.rawValue | last.rawValue
}

public struct BLEFramingLimits: Equatable, Sendable {
    public static let `default` = BLEFramingLimits()
    public static let headerBytes = 16
    public static let minimumValueLength = 20
    public static let maximumEnvelopeBytes = 8_192
    public static let maximumFragments = 2_048
    public static let maximumQueuedFrames = 128
    public static let maximumReliableInFlight = 32
    public static let maximumAttempts = 3
    public static let acknowledgementTimeout: TimeInterval = 0.5

    public var maximumEnvelopeBytes: Int
    public var maximumFragments: Int
    public var maximumQueuedFrames: Int
    public var maximumReliableInFlight: Int
    public var maximumAttempts: Int
    public var acknowledgementTimeout: TimeInterval

    public init(
        maximumEnvelopeBytes: Int = BLEFramingLimits.maximumEnvelopeBytes,
        maximumFragments: Int = BLEFramingLimits.maximumFragments,
        maximumQueuedFrames: Int = BLEFramingLimits.maximumQueuedFrames,
        maximumReliableInFlight: Int = BLEFramingLimits.maximumReliableInFlight,
        maximumAttempts: Int = BLEFramingLimits.maximumAttempts,
        acknowledgementTimeout: TimeInterval = BLEFramingLimits.acknowledgementTimeout
    ) {
        self.maximumEnvelopeBytes = max(1, maximumEnvelopeBytes)
        self.maximumFragments = max(1, maximumFragments)
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
        self.maximumReliableInFlight = max(1, maximumReliableInFlight)
        self.maximumAttempts = max(1, maximumAttempts)
        self.acknowledgementTimeout = max(0.001, acknowledgementTimeout)
    }
}

public struct BLEFrame: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let headerBytes = BLEFramingLimits.headerBytes

    public let kind: BLEFrameKind
    public let flags: BLEFrameFlags
    public let messageID: UInt32
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let payload: Data

    public init(
        kind: BLEFrameKind,
        flags: BLEFrameFlags,
        messageID: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        payload: Data
    ) throws {
        guard messageID != 0, !payload.isEmpty else { throw BLEFramingError.emptyPayload }
        guard fragmentCount > 0,
              Int(fragmentCount) <= BLEFramingLimits.maximumFragments,
              fragmentIndex < fragmentCount else { throw BLEFramingError.invalidFragmentIndex }
        guard flags.rawValue & ~BLEFrameFlags.validBits == 0 else { throw BLEFramingError.invalidFlags }
        let expectedFirst = fragmentIndex == 0
        let expectedLast = fragmentIndex == fragmentCount - 1
        guard flags.contains(.first) == expectedFirst, flags.contains(.last) == expectedLast else {
            throw BLEFramingError.invalidFlags
        }
        self.kind = kind
        self.flags = flags
        self.messageID = messageID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payload = payload
    }

    public func encode(maximumValueLength: Int) throws -> Data {
        guard maximumValueLength >= BLEFramingLimits.headerBytes + 1 else {
            throw BLEFramingError.valueLengthTooSmall
        }
        guard maximumValueLength <= Int(UInt16.max) else { throw BLEFramingError.valueLengthTooLarge }
        guard payload.count <= maximumValueLength - BLEFramingLimits.headerBytes else {
            throw BLEFramingError.invalidLength
        }
        var output = Data()
        output.append(BLEFrame.version)
        output.append(kind.rawValue)
        output.append(flags.rawValue)
        output.append(0)
        output.append(contentsOf: Self.uInt32Bytes(messageID))
        output.append(contentsOf: Self.uInt16Bytes(fragmentIndex))
        output.append(contentsOf: Self.uInt16Bytes(fragmentCount))
        output.append(contentsOf: Self.uInt16Bytes(UInt16(payload.count)))
        output.append(contentsOf: [0, 0])
        output.append(payload)
        return output
    }

    public static func decode(_ data: Data, maximumValueLength: Int) throws -> BLEFrame {
        guard maximumValueLength >= BLEFramingLimits.headerBytes + 1 else {
            throw BLEFramingError.valueLengthTooSmall
        }
        guard data.count >= BLEFramingLimits.headerBytes + 1,
              data.count <= maximumValueLength else { throw BLEFramingError.invalidLength }
        guard data[0] == Self.version else { throw BLEFramingError.unsupportedVersion }
        guard let kind = BLEFrameKind(rawValue: data[1]) else { throw BLEFramingError.unknownFrameKind }
        let flags = BLEFrameFlags(rawValue: data[2])
        guard flags.rawValue & ~BLEFrameFlags.validBits == 0, data[3] == 0,
              data[14] == 0, data[15] == 0 else { throw BLEFramingError.invalidFlags }
        let messageID = readUInt32(data, offset: 4)
        let fragmentIndex = readUInt16(data, offset: 8)
        let fragmentCount = readUInt16(data, offset: 10)
        let payloadLength = readUInt16(data, offset: 12)
        guard messageID != 0,
              fragmentCount > 0,
              Int(fragmentCount) <= BLEFramingLimits.maximumFragments,
              fragmentIndex < fragmentCount,
              Int(payloadLength) == data.count - BLEFramingLimits.headerBytes else {
            throw BLEFramingError.invalidLength
        }
        let expectedFirst = fragmentIndex == 0
        let expectedLast = fragmentIndex == fragmentCount - 1
        guard flags.contains(.first) == expectedFirst, flags.contains(.last) == expectedLast else {
            throw BLEFramingError.invalidFlags
        }
        let payload = data.subdata(in: BLEFramingLimits.headerBytes..<data.count)
        return try BLEFrame(
            kind: kind,
            flags: flags,
            messageID: messageID,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payload: payload
        )
    }

    private static func uInt16Bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xff)]
    }

    private static func uInt32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}

public struct BLEFragmenter: Sendable {
    public let limits: BLEFramingLimits

    public init(limits: BLEFramingLimits = .default) { self.limits = limits }

    public func fragment(
        payload: Data,
        kind: BLEFrameKind,
        reliable: Bool,
        messageID: UInt32,
        maximumValueLength: Int
    ) throws -> [Data] {
        guard !payload.isEmpty else { throw BLEFramingError.emptyPayload }
        guard payload.count <= limits.maximumEnvelopeBytes else { throw BLEFramingError.envelopeTooLarge }
        guard maximumValueLength >= BLEFramingLimits.headerBytes + 1 else {
            throw BLEFramingError.valueLengthTooSmall
        }
        guard maximumValueLength <= Int(UInt16.max) else { throw BLEFramingError.valueLengthTooLarge }
        let fragmentPayloadBytes = maximumValueLength - BLEFramingLimits.headerBytes
        let fragmentCount = Int(ceil(Double(payload.count) / Double(fragmentPayloadBytes)))
        guard fragmentCount <= limits.maximumFragments, fragmentCount <= Int(UInt16.max) else {
            throw BLEFramingError.tooManyFragments
        }
        let count = UInt16(fragmentCount)
        var result: [Data] = []
        result.reserveCapacity(fragmentCount)
        for index in 0..<fragmentCount {
            let start = index * fragmentPayloadBytes
            let end = min(start + fragmentPayloadBytes, payload.count)
            var flags: BLEFrameFlags = []
            if reliable { flags.insert(.reliable) }
            if index == 0 { flags.insert(.first) }
            if index == fragmentCount - 1 { flags.insert(.last) }
            let frame = try BLEFrame(
                kind: kind,
                flags: flags,
                messageID: messageID,
                fragmentIndex: UInt16(index),
                fragmentCount: count,
                payload: payload.subdata(in: start..<end)
            )
            result.append(try frame.encode(maximumValueLength: maximumValueLength))
        }
        return result
    }
}

public enum BLEReassemblyResult: Equatable, Sendable {
    case incomplete
    case complete(payload: Data, kind: BLEFrameKind, reliable: Bool, messageID: UInt32)
    case duplicate
}

public final class BLEReassembler {
    private struct Partial {
        let kind: BLEFrameKind
        let reliable: Bool
        let fragmentCount: UInt16
        var nextIndex: UInt16
        var payload: Data
    }

    public let limits: BLEFramingLimits
    private let maximumValueLength: Int
    private var partials: [UInt32: Partial] = [:]
    private var completedIDs: [UInt32] = []
    private var completedSet: Set<UInt32> = []

    public init(maximumValueLength: Int, limits: BLEFramingLimits = .default) throws {
        guard maximumValueLength >= BLEFramingLimits.headerBytes + 1 else {
            throw BLEFramingError.valueLengthTooSmall
        }
        self.maximumValueLength = maximumValueLength
        self.limits = limits
    }

    public func append(_ encodedFrame: Data) throws -> BLEReassemblyResult {
        let frame = try BLEFrame.decode(encodedFrame, maximumValueLength: maximumValueLength)
        if completedSet.contains(frame.messageID) { return .duplicate }
        if var partial = partials[frame.messageID] {
            guard partial.kind == frame.kind,
                  partial.reliable == frame.flags.contains(.reliable),
                  partial.fragmentCount == frame.fragmentCount else {
                partials.removeValue(forKey: frame.messageID)
                throw BLEFramingError.conflictingFragment
            }
            guard frame.fragmentIndex == partial.nextIndex else {
                if frame.fragmentIndex < partial.nextIndex { return .duplicate }
                partials.removeValue(forKey: frame.messageID)
                throw BLEFramingError.outOfOrderFragment
            }
            partial.payload.append(frame.payload)
            guard partial.payload.count <= limits.maximumEnvelopeBytes else {
                partials.removeValue(forKey: frame.messageID)
                throw BLEFramingError.envelopeTooLarge
            }
            partial.nextIndex += 1
            if frame.flags.contains(.last) {
                guard partial.nextIndex == partial.fragmentCount else {
                    partials.removeValue(forKey: frame.messageID)
                    throw BLEFramingError.invalidFragmentIndex
                }
                partials.removeValue(forKey: frame.messageID)
                rememberCompleted(frame.messageID)
                return .complete(payload: partial.payload, kind: partial.kind, reliable: partial.reliable, messageID: frame.messageID)
            }
            partials[frame.messageID] = partial
            return .incomplete
        }
        guard frame.flags.contains(.first), frame.fragmentIndex == 0 else {
            throw BLEFramingError.outOfOrderFragment
        }
        let partial = Partial(
            kind: frame.kind,
            reliable: frame.flags.contains(.reliable),
            fragmentCount: frame.fragmentCount,
            nextIndex: 1,
            payload: frame.payload
        )
        guard partial.payload.count <= limits.maximumEnvelopeBytes else { throw BLEFramingError.envelopeTooLarge }
        if frame.flags.contains(.last) {
            rememberCompleted(frame.messageID)
            return .complete(payload: partial.payload, kind: partial.kind, reliable: partial.reliable, messageID: frame.messageID)
        }
        partials[frame.messageID] = partial
        guard partials.count <= limits.maximumReliableInFlight else {
            partials.removeValue(forKey: frame.messageID)
            throw BLEFramingError.reliableWindowFull
        }
        return .incomplete
    }

    public func reset() {
        partials.removeAll(keepingCapacity: true)
        completedIDs.removeAll(keepingCapacity: true)
        completedSet.removeAll(keepingCapacity: true)
    }

    public var partialMessageCount: Int { partials.count }
    public var partialBytes: Int { partials.values.reduce(0) { $0 + $1.payload.count } }

    private func rememberCompleted(_ id: UInt32) {
        completedIDs.append(id)
        completedSet.insert(id)
        while completedIDs.count > limits.maximumReliableInFlight * 4 {
            let old = completedIDs.removeFirst()
            completedSet.remove(old)
        }
    }
}

public struct BLERetryAction: Equatable, Sendable {
    public let messageID: UInt32
    public let attempt: Int
    public let frames: [Data]
}

/// A bounded scheduler for reliable/unreliable fragmented messages. The
/// adapter drains `nextFrames()` only when Core Bluetooth reports capacity.
public final class BLEOutboundScheduler {
    private struct Item {
        let messageID: UInt32
        let reliable: Bool
        let frames: [Data]
        var attempt: Int
        var acknowledged: Bool
        var deadline: Date?
    }

    public let limits: BLEFramingLimits
    private let fragmenter: BLEFragmenter
    private let maximumValueLength: Int
    private var queue: [Data] = []
    private var items: [UInt32: Item] = [:]
    private var order: [UInt32] = []

    public init(maximumValueLength: Int, limits: BLEFramingLimits = .default) throws {
        self.limits = limits
        self.fragmenter = BLEFragmenter(limits: limits)
        guard maximumValueLength >= BLEFramingLimits.headerBytes + 1 else {
            throw BLEFramingError.valueLengthTooSmall
        }
        self.maximumValueLength = maximumValueLength
    }

    @discardableResult
    public func enqueue(payload: Data, kind: BLEFrameKind, reliable: Bool, messageID: UInt32, now: Date) throws -> Int {
        guard queue.count < limits.maximumQueuedFrames else { throw BLEFramingError.queueFull }
        if reliable {
            let inFlight = items.values.filter { $0.reliable && !$0.acknowledged }.count
            guard inFlight < limits.maximumReliableInFlight else { throw BLEFramingError.reliableWindowFull }
        }
        let frames = try fragmenter.fragment(
            payload: payload,
            kind: kind,
            reliable: reliable,
            messageID: messageID,
            maximumValueLength: maximumValueLength
        )
        guard queue.count + frames.count <= limits.maximumQueuedFrames else { throw BLEFramingError.queueFull }
        queue.append(contentsOf: frames)
        items[messageID] = Item(messageID: messageID, reliable: reliable, frames: frames, attempt: 1, acknowledged: false, deadline: reliable ? now.addingTimeInterval(limits.acknowledgementTimeout) : nil)
        order.append(messageID)
        return frames.count
    }

    public func nextFrames(maximum: Int = Int.max) -> [Data] {
        guard maximum > 0 else { return [] }
        let count = min(maximum, queue.count)
        let frames = Array(queue.prefix(count))
        queue.removeFirst(count)
        return frames
    }

    public func acknowledge(messageID: UInt32) {
        guard var item = items[messageID] else { return }
        item.acknowledged = true
        item.deadline = nil
        items[messageID] = item
        cleanup(messageID: messageID)
    }

    public func retryActions(now: Date) -> [BLERetryAction] {
        var actions: [BLERetryAction] = []
        for id in order {
            guard var item = items[id], item.reliable, !item.acknowledged,
                  let deadline = item.deadline, now >= deadline else { continue }
            guard item.attempt < limits.maximumAttempts else {
                // Keep the deadline visible so the caller can report the
                // exhausted message through `expiredReliableIDs`. The item
                // is already at its attempt limit and therefore emits no
                // further retry action.
                continue
            }
            item.attempt += 1
            item.deadline = now.addingTimeInterval(limits.acknowledgementTimeout)
            items[id] = item
            actions.append(BLERetryAction(messageID: id, attempt: item.attempt, frames: item.frames))
        }
        return actions
    }

    public func expiredReliableIDs(now: Date) -> [UInt32] {
        order.compactMap { id in
            guard let item = items[id], item.reliable, !item.acknowledged,
                  let deadline = item.deadline, now >= deadline, item.attempt >= limits.maximumAttempts else { return nil }
            return id
        }
    }

    public func reset() {
        queue.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    public var queuedFrameCount: Int { queue.count }
    public var reliableInFlightCount: Int { items.values.filter { $0.reliable && !$0.acknowledged }.count }

    private func cleanup(messageID: UInt32) {
        guard let index = order.firstIndex(of: messageID) else { return }
        order.remove(at: index)
        items.removeValue(forKey: messageID)
    }
}

private func readUInt16(_ data: Data, offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) |
    (UInt32(data[offset + 1]) << 16) |
    (UInt32(data[offset + 2]) << 8) |
    UInt32(data[offset + 3])
}
