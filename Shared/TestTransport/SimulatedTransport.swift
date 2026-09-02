/// Deterministic in-process byte transport for protocol, UI, and safety tests.
/// No production target needs to instantiate this implementation; production
/// adapters only depend on `RemoteTransportEndpoint`.
public final class SimulatedTransport {
    public struct Configuration: Equatable {
        public var delayTicks: UInt64
        public var lossRatePermille: UInt16
        public var duplicationRatePermille: UInt16
        public var reorderingWindow: Int
        public var maximumQueueDepth: Int
        public var seed: UInt64

        public init(
            delayTicks: UInt64 = 0,
            lossRatePermille: UInt16 = 0,
            duplicationRatePermille: UInt16 = 0,
            reorderingWindow: Int = 0,
            maximumQueueDepth: Int = 64,
            seed: UInt64 = 1
        ) {
            precondition(lossRatePermille <= 1_000, "loss rate must be in 0...1000")
            precondition(duplicationRatePermille <= 1_000, "duplication rate must be in 0...1000")
            precondition(reorderingWindow >= 0, "reordering window cannot be negative")
            precondition(maximumQueueDepth > 0, "queue depth must be positive")
            self.delayTicks = delayTicks
            self.lossRatePermille = lossRatePermille
            self.duplicationRatePermille = duplicationRatePermille
            self.reorderingWindow = reorderingWindow
            self.maximumQueueDepth = maximumQueueDepth
            self.seed = seed
        }
    }

    public enum Direction: Equatable {
        case aToB
        case bToA
        case none
    }

    public enum TraceKind: Equatable {
        case connected
        case disconnected
        case queued
        case delivered
        case dropped
        case duplicated
        case overflow
    }

    /// Trace entries contain only sizes and control metadata, never payload
    /// bytes. This makes them safe to retain in tests and local diagnostics.
    public struct TraceEvent: Equatable {
        public let tick: UInt64
        public let kind: TraceKind
        public let direction: Direction
        public let byteCount: Int

        public init(tick: UInt64, kind: TraceKind, direction: Direction, byteCount: Int) {
            self.tick = tick
            self.kind = kind
            self.direction = direction
            self.byteCount = byteCount
        }
    }

    private struct Packet {
        let id: UInt64
        let direction: Direction
        let bytes: [UInt8]
        let deliverAt: UInt64
    }

    private var configuration: Configuration
    private var randomState: UInt64
    private var nextPacketID: UInt64 = 1
    private var pending: [Packet] = []
    private var currentTick: UInt64 = 0
    private var connected = false
    private var trace: [TraceEvent] = []

    public let endpointA: Endpoint
    public let endpointB: Endpoint

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.randomState = configuration.seed == 0 ? 1 : configuration.seed
        self.endpointA = Endpoint(role: .a, direction: .aToB)
        self.endpointB = Endpoint(role: .b, direction: .bToA)
        self.endpointA.transport = self
        self.endpointB.transport = self
    }

    public var now: UInt64 { currentTick }

    public var traceEvents: [TraceEvent] { trace }

    public var queuedPacketCount: Int { pending.count }

    public func connect() {
        guard !connected else { return }
        connected = true
        endpointA.emit(.connected)
        endpointB.emit(.connected)
        append(.connected, direction: .none, byteCount: 0)
    }

    public func disconnect() {
        guard connected else { return }
        connected = false
        pending.removeAll(keepingCapacity: false)
        endpointA.emit(.disconnected)
        endpointB.emit(.disconnected)
        append(.disconnected, direction: .none, byteCount: 0)
    }

    /// Move the deterministic clock forward and deliver all due packets.
    public func advance(by ticks: UInt64 = 1) {
        currentTick &+= ticks
        drain()
    }

    /// Deliver packets due at the current clock value. Calling this twice with
    /// no clock movement is deterministic and produces no duplicate delivery.
    public func drain() {
        while let index = nextDuePacketIndex() {
            let packet = pending.remove(at: index)
            guard connected else { continue }
            let endpoint = packet.direction == .aToB ? endpointB : endpointA
            append(.delivered, direction: packet.direction, byteCount: packet.bytes.count)
            endpoint.onReceive?(packet.bytes)
        }
    }

    public final class Endpoint: RemoteTransportEndpoint {
        fileprivate enum Role { case a, b }

        fileprivate weak var transport: SimulatedTransport?
        fileprivate let role: Role
        fileprivate let direction: Direction

        public var onReceive: (([UInt8]) -> Void)?
        public var onStateChange: ((TransportConnectionState) -> Void)?

        fileprivate init(role: Role, direction: Direction) {
            self.role = role
            self.direction = direction
        }

        public var isConnected: Bool { transport?.connected ?? false }

        @discardableResult
        public func send(_ bytes: [UInt8]) -> TransportSendResult {
            transport?.enqueue(bytes: bytes, direction: direction) ?? .disconnected
        }

        public func disconnect() {
            transport?.disconnect()
        }

        fileprivate func emit(_ state: TransportConnectionState) {
            onStateChange?(state)
        }
    }

    private func enqueue(bytes: [UInt8], direction: Direction) -> TransportSendResult {
        guard connected else {
            append(.disconnected, direction: direction, byteCount: bytes.count)
            return .disconnected
        }

        guard !shouldDrop() else {
            append(.dropped, direction: direction, byteCount: bytes.count)
            return .dropped
        }

        let duplicate = shouldDuplicate()
        let copyCount = duplicate ? 2 : 1
        guard pending.count + copyCount <= configuration.maximumQueueDepth else {
            append(.overflow, direction: direction, byteCount: bytes.count)
            return .overflow
        }

        for copy in 0..<copyCount {
            let packet = Packet(
                id: nextPacketID,
                direction: direction,
                bytes: bytes,
                deliverAt: currentTick &+ configuration.delayTicks
            )
            nextPacketID &+= 1
            pending.append(packet)
            append(copy == 0 ? .queued : .duplicated, direction: direction, byteCount: bytes.count)
        }
        return .queued
    }

    private func nextDuePacketIndex() -> Int? {
        guard !pending.isEmpty else { return nil }
        let dueIndices = pending.indices.filter { pending[$0].deliverAt <= currentTick }
        guard !dueIndices.isEmpty else { return nil }

        guard configuration.reorderingWindow > 1 else { return dueIndices[0] }
        let candidateCount = min(configuration.reorderingWindow, dueIndices.count)
        let selectedOffset = Int(nextRandom() % UInt64(candidateCount))
        return dueIndices[selectedOffset]
    }

    private func shouldDrop() -> Bool {
        guard configuration.lossRatePermille > 0 else { return false }
        return nextRandom() % 1_000 < UInt64(configuration.lossRatePermille)
    }

    private func shouldDuplicate() -> Bool {
        guard configuration.duplicationRatePermille > 0 else { return false }
        return nextRandom() % 1_000 < UInt64(configuration.duplicationRatePermille)
    }

    /// Small deterministic LCG. The transport is a test fixture, not a source
    /// of security randomness; the seed is exposed so traces are reproducible.
    private func nextRandom() -> UInt64 {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
        return randomState
    }

    private func append(_ kind: TraceKind, direction: Direction, byteCount: Int) {
        trace.append(TraceEvent(tick: currentTick, kind: kind, direction: direction, byteCount: byteCount))
    }
}

