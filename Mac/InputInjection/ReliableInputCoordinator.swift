import Foundation

public protocol InputSafetyClock: AnyObject {
    var now: TimeInterval { get }
}

public final class MonotonicInputSafetyClock: InputSafetyClock {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

public struct ReliableInputAction: Equatable, Sendable {
    public let actionID: UInt64
    public let command: RemoteInputCommand

    public init(actionID: UInt64, command: RemoteInputCommand) {
        self.actionID = actionID
        self.command = command
    }
}

public struct InputHeartbeat: Equatable, Sendable {
    public let held: HeldInputState

    public init(held: HeldInputState = HeldInputState()) {
        self.held = held
    }
}

public enum ReliableInputEvent: Equatable, Sendable {
    case applied(actionID: UInt64)
    case acknowledgement(actionID: UInt64)
    case denied(actionID: UInt64, reason: SafetyDenialReason)
    case failed(actionID: UInt64)
    case reconciled
    case watchdogExpired
    case released(reason: ReleaseReason)
}

/// Handles reliable transitions at the safety boundary.  Action identifiers
/// are retained in a bounded cache: a duplicate can be acknowledged but is
/// never posted to the sink twice.
public final class ReliableInputCoordinator {
    public let heartbeatTimeout: TimeInterval
    private let injector: SafeInputInjector
    private let clock: InputSafetyClock
    private var lastHeartbeat: TimeInterval?
    private var watchdogArmed = false
    private var appliedActionIDs: Set<UInt64> = []
    private var actionOrder: [UInt64] = []
    private let maxRememberedActions: Int

    public init(
        injector: SafeInputInjector,
        clock: InputSafetyClock = MonotonicInputSafetyClock(),
        heartbeatTimeout: TimeInterval = 0.5,
        maxRememberedActions: Int = 2_048
    ) {
        self.injector = injector
        self.clock = clock
        self.heartbeatTimeout = max(0.05, heartbeatTimeout)
        self.maxRememberedActions = max(1, maxRememberedActions)
    }

    @discardableResult
    public func receive(_ action: ReliableInputAction, at timestamp: TimeInterval? = nil) -> [ReliableInputEvent] {
        let now = timestamp ?? clock.now
        if appliedActionIDs.contains(action.actionID) {
            return [.acknowledgement(actionID: action.actionID)]
        }

        watchdogArmed = true
        lastHeartbeat = now
        let result = injector.submit(action.command)
        remember(action.actionID)
        switch result {
        case .applied:
            return [.applied(actionID: action.actionID), .acknowledgement(actionID: action.actionID)]
        case let .denied(reason):
            return [.denied(actionID: action.actionID, reason: reason), .acknowledgement(actionID: action.actionID)]
        case .failed:
            return [.failed(actionID: action.actionID), .acknowledgement(actionID: action.actionID)]
        }
    }

    @discardableResult
    public func receive(heartbeat: InputHeartbeat, at timestamp: TimeInterval? = nil) -> [ReliableInputEvent] {
        let now = timestamp ?? clock.now
        watchdogArmed = true
        lastHeartbeat = now
        _ = injector.reconcile(held: heartbeat.held)
        return [.reconciled]
    }

    /// Poll from the app's normal run loop.  A single expiry releases all
    /// state; repeated polls remain quiet until another valid heartbeat arrives.
    @discardableResult
    public func poll(at timestamp: TimeInterval? = nil) -> [ReliableInputEvent] {
        guard watchdogArmed, let lastHeartbeat else { return [] }
        let now = timestamp ?? clock.now
        guard now - lastHeartbeat >= heartbeatTimeout else { return [] }
        watchdogArmed = false
        self.lastHeartbeat = nil
        _ = injector.releaseAllInputs(reason: .heartbeatTimeout)
        return [.watchdogExpired, .released(reason: .heartbeatTimeout)]
    }

    @discardableResult
    public func disconnect() -> [ReliableInputEvent] {
        watchdogArmed = false
        lastHeartbeat = nil
        appliedActionIDs.removeAll(keepingCapacity: true)
        actionOrder.removeAll(keepingCapacity: true)
        _ = injector.releaseAllInputs(reason: .disconnect)
        return [.released(reason: .disconnect)]
    }

    private func remember(_ actionID: UInt64) {
        guard appliedActionIDs.insert(actionID).inserted else { return }
        actionOrder.append(actionID)
        if actionOrder.count > maxRememberedActions {
            let evicted = actionOrder.removeFirst()
            appliedActionIDs.remove(evicted)
        }
    }
}

public enum ReliableRetryEvent: Equatable, Sendable {
    case retry(ReliableInputAction, attempt: Int)
    case exhausted(ReliableInputAction)
}

private struct PendingReliableAction {
    var action: ReliableInputAction
    var attempt: Int
    var deadline: TimeInterval
}

/// Outbound retry bookkeeping for button/modifier transitions.  Transport
/// adapters call acknowledge(_:) when the peer confirms an action.  It has a
/// finite retry budget and a bounded pending queue.
public struct ReliableRetryTracker: Sendable {
    public let acknowledgementTimeout: TimeInterval
    public let maxAttempts: Int
    public let maxPending: Int
    private var pending: [UInt64: PendingReliableAction] = [:]

    public init(
        acknowledgementTimeout: TimeInterval = 0.15,
        maxAttempts: Int = 3,
        maxPending: Int = 128
    ) {
        self.acknowledgementTimeout = max(0.01, acknowledgementTimeout)
        self.maxAttempts = max(1, maxAttempts)
        self.maxPending = max(1, maxPending)
    }

    public var pendingCount: Int { pending.count }

    /// Returns false when the queue is full or an action ID is already pending.
    public mutating func enqueue(_ action: ReliableInputAction, at timestamp: TimeInterval) -> Bool {
        guard action.command.delivery == .reliable,
              pending[action.actionID] == nil,
              pending.count < maxPending else { return false }
        pending[action.actionID] = PendingReliableAction(
            action: action,
            attempt: 1,
            deadline: timestamp + acknowledgementTimeout
        )
        return true
    }

    public mutating func acknowledge(actionID: UInt64) {
        pending.removeValue(forKey: actionID)
    }

    public mutating func poll(at timestamp: TimeInterval) -> [ReliableRetryEvent] {
        let due = pending.values.filter { timestamp >= $0.deadline }
        var events: [ReliableRetryEvent] = []
        for current in due {
            guard var item = pending[current.action.actionID] else { continue }
            if item.attempt >= maxAttempts {
                pending.removeValue(forKey: item.action.actionID)
                events.append(.exhausted(item.action))
            } else {
                item.attempt += 1
                item.deadline = timestamp + acknowledgementTimeout
                pending[item.action.actionID] = item
                events.append(.retry(item.action, attempt: item.attempt))
            }
        }
        return events.sorted {
            actionID(for: $0) < actionID(for: $1)
        }
    }

    private func actionID(for event: ReliableRetryEvent) -> UInt64 {
        switch event {
        case let .retry(action, _), let .exhausted(action): return action.actionID
        }
    }
}
