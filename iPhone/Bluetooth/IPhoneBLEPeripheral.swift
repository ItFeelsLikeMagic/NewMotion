import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
#endif

public enum BLEPeripheralSendResult: Equatable {
    case sent
    case queued
    case notReady
    case queueFull
    case unsupportedChannel
}

public struct BLEPeripheralWrite: Equatable {
    public let characteristic: UUID
    public let data: Data
    public let subscriberID: String

    public init(characteristic: UUID, data: Data, subscriberID: String = "") {
        self.characteristic = characteristic
        self.data = data
        self.subscriberID = subscriberID
    }
}

public protocol IPhonePeripheralManagerAdapter: AnyObject {
    var state: BLEPeripheralManagerState { get }
    var maximumUpdateValueLength: Int { get }
    var onStateChange: ((BLEPeripheralManagerState) -> Void)? { get set }
    var onServicePublished: ((UUID, Error?) -> Void)? { get set }
    var onSubscribe: ((String, UUID) -> Void)? { get set }
    var onUnsubscribe: ((String, UUID) -> Void)? { get set }
    var onWrite: ((BLEPeripheralWrite) -> Void)? { get set }
    var onReadyToUpdateSubscribers: (() -> Void)? { get set }
    var onAdvertisingStarted: ((Error?) -> Void)? { get set }

    func publish(serviceUUID: UUID, characteristics: [BLECharacteristicDefinition])
    func startAdvertising(localName: String, serviceUUID: UUID)
    func stopAdvertising()
    func removeAllServices()
    @discardableResult
    func updateValue(_ data: Data, characteristicUUID: UUID) -> Bool
}

/// State and queue logic is isolated from Core Bluetooth so all lifecycle and
/// backpressure behavior can be tested with a deterministic fake adapter.
///
/// The GATT service is always `NewMotionGATT.serviceUUID`; what the air
/// carries is the beacon, which names the one Mac this phone means to reach.
/// Without a beacon the service is published but never advertised.
public final class IPhoneBLEPeripheralTransport {
    public let serviceUUID = NewMotionGATT.serviceUUID
    public private(set) var state: BLEPeripheralLifecycleState = .idle
    public private(set) var beacon: UUID?
    public private(set) var isForeground = false
    public private(set) var subscribedCharacteristicUUIDs: Set<UUID> = []
    public private(set) var subscriberIDs: Set<String> = []
    /// Core Bluetooth does not currently expose a negotiated notify length on
    /// the peripheral side, so the adapter supplies the ATT-safe minimum for
    /// framing. Keeping it on the transport makes the pairing bridge use the
    /// same bound as any future feature bridge or test adapter.
    public var maximumUpdateValueLength: Int {
        max(BLEFramingLimits.minimumValueLength, adapter.maximumUpdateValueLength)
    }

    public var onStateChange: ((BLEPeripheralLifecycleState) -> Void)?
    public var onFrameReceived: ((BLETransportChannel, Data) -> Void)?
    public var onQueueFull: ((BLETransportChannel) -> Void)?
    /// Fires when Core Bluetooth has room again.  Senders that hold a summed
    /// delta instead of queueing it use this to push it out immediately.
    public var onReadyToSend: (() -> Void)?
    public var onTransportError: ((Error) -> Void)?

    private let adapter: IPhonePeripheralManagerAdapter
    private let localName: String
    private let queueLimit: Int
    private var outbound: [BLETransportChannel: [Data]] = [.data: [], .control: []]
    private var hasPublishedService = false

    public init(
        adapter: IPhonePeripheralManagerAdapter,
        localName: String = "NewMotion",
        queueLimit: Int = BLEFramingLimits.maximumQueuedFrames
    ) {
        self.adapter = adapter
        self.localName = localName
        self.queueLimit = max(1, queueLimit)
        adapter.onStateChange = { [weak self] state in self?.handleManagerState(state) }
        adapter.onServicePublished = { [weak self] uuid, error in self?.handleServicePublished(uuid: uuid, error: error) }
        adapter.onSubscribe = { [weak self] subscriber, uuid in self?.handleSubscribe(subscriber: subscriber, uuid: uuid) }
        adapter.onUnsubscribe = { [weak self] subscriber, uuid in self?.handleUnsubscribe(subscriber: subscriber, uuid: uuid) }
        adapter.onWrite = { [weak self] write in self?.handleWrite(write) }
        adapter.onReadyToUpdateSubscribers = { [weak self] in self?.flushAll() }
        adapter.onAdvertisingStarted = { [weak self] error in self?.handleAdvertisingStarted(error) }
        handleManagerState(adapter.state)
    }

    /// A live advertisement changes over in place; a connection keeps its
    /// central and the next advertisement carries the new beacon.
    public func setBeacon(_ beacon: UUID?) {
        guard beacon != self.beacon else { return }
        self.beacon = beacon
        switch state {
        case .advertising:
            adapter.stopAdvertising()
            advertiseIfAddressed()
        case .stopped:
            startIfAllowed()
        case .idle, .waitingForBluetooth, .publishing, .connected, .ready:
            return
        }
    }

    /// Advertising is deliberately gated by both foreground state and
    /// powered-on Bluetooth. Backgrounding takes the whole service down, not
    /// just the beacon: a suspended app cannot answer the Mac, and iOS tells
    /// it nothing about a link that dies while it sleeps. Leaving the service
    /// up left the phone believing in a subscriber that was long gone, so it
    /// never advertised again and the Mac scanned forever. Removing the
    /// service is the one thing a peripheral can do that the Mac notices at
    /// once; it drops the link and scans, and the next foreground republishes
    /// into a fresh connection.
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            startIfAllowed()
        } else {
            stop(reason: .stopped)
        }
    }

    public func startIfAllowed() {
        guard isForeground else { return }
        guard adapter.state == .poweredOn else {
            transition(to: .waitingForBluetooth)
            return
        }
        switch state {
        case .connected, .ready, .publishing, .advertising:
            // A live or in-flight Mac link must not be reset back to advertising.
            // Calling startAdvertising again can error and tear the beacon down.
            return
        case .idle, .waitingForBluetooth, .stopped:
            break
        }
        guard hasPublishedService else {
            transition(to: .publishing)
            adapter.publish(serviceUUID: serviceUUID, characteristics: NewMotionGATT.characteristics)
            return
        }
        advertiseIfAddressed()
    }

    /// The state has to say whether the beacon is really lit; claiming
    /// `.advertising` with nothing on the air would make the next start skip
    /// lighting it.
    private func advertiseIfAddressed() {
        guard let beacon else {
            transition(to: .stopped)
            return
        }
        transition(to: .advertising)
        adapter.startAdvertising(localName: localName, serviceUUID: beacon)
    }

    /// Refreshes advertising so a Mac that began scanning late still sees us.
    /// Never stops an in-flight advertisement; that drops centrals mid-connect
    /// and breaks QR pairing.
    public func pulseAdvertising() {
        guard isForeground, adapter.state == .poweredOn else { return }
        switch state {
        case .ready, .connected, .publishing, .advertising:
            return
        case .idle, .stopped, .waitingForBluetooth:
            startIfAllowed()
        }
    }

    public func stop(reason: BLEPeripheralLifecycleState = .stopped) {
        adapter.stopAdvertising()
        adapter.removeAllServices()
        hasPublishedService = false
        subscribedCharacteristicUUIDs.removeAll()
        subscriberIDs.removeAll()
        outbound[.data]?.removeAll(keepingCapacity: true)
        outbound[.control]?.removeAll(keepingCapacity: true)
        transition(to: reason)
    }

    @discardableResult
    public func send(_ data: Data, on channel: BLETransportChannel, enqueue: Bool = true) -> BLEPeripheralSendResult {
        let characteristic: UUID
        switch channel {
        case .data: characteristic = NewMotionGATT.phoneToMacDataUUID
        case .control: characteristic = NewMotionGATT.phoneToMacControlUUID
        }
        guard !data.isEmpty else { return .notReady }
        guard state == .ready || state == .connected else { return .notReady }
        guard subscriberIDs.isEmpty == false else { return .notReady }
        if adapter.updateValue(data, characteristicUUID: characteristic) {
            return .sent
        }
        guard enqueue else { return .queueFull }
        guard let count = outbound[channel]?.count, count < queueLimit else {
            onQueueFull?(channel)
            return .queueFull
        }
        outbound[channel, default: []].append(data)
        return .queued
    }

    public var queuedFrameCount: Int { outbound.values.reduce(0) { $0 + $1.count } }

    /// Free outbound slots while the Mac is subscribed.  Callers use it to
    /// drop a multi-fragment message whole instead of sending part of it.
    public func queueCapacity(on channel: BLETransportChannel) -> Int {
        guard state == .ready else { return 0 }
        return queueLimit - (outbound[channel]?.count ?? 0)
    }

    private func handleManagerState(_ managerState: BLEPeripheralManagerState) {
        switch managerState {
        case .poweredOn:
            startIfAllowed()
        case .unknown, .resetting, .unsupported, .unauthorized, .poweredOff:
            if isForeground { stop(reason: .waitingForBluetooth) }
        }
    }

    private func handleServicePublished(uuid: UUID, error: Error?) {
        guard uuid == serviceUUID else { return }
        if let error {
            onTransportError?(error)
            stop(reason: .stopped)
            return
        }
        hasPublishedService = true
        guard isForeground, adapter.state == .poweredOn else { return }
        advertiseIfAddressed()
    }

    private func handleAdvertisingStarted(_ error: Error?) {
        guard error != nil else { return }
        IPhoneDebugLog.emit("advertise_error", ["state": "\(state)"])
        // Stay published. A second startAdvertising call can error even when
        // the first beacon is live; tearing down here makes Confirm fail.
    }

    private func handleSubscribe(subscriber: String, uuid: UUID) {
        guard NewMotionGATT.allCharacteristicUUIDs.contains(uuid) else { return }
        // Only one Mac is ever subscribed, so a different central means the
        // old link is gone whether or not iOS delivered its unsubscribe. The
        // trip through `.advertising` is what tells the app to handshake again.
        if !subscriberIDs.isEmpty, !subscriberIDs.contains(subscriber) {
            subscriberIDs.removeAll()
            subscribedCharacteristicUUIDs.removeAll()
            outbound[.data]?.removeAll(keepingCapacity: true)
            outbound[.control]?.removeAll(keepingCapacity: true)
            transition(to: .advertising)
        }
        subscriberIDs.insert(subscriber)
        subscribedCharacteristicUUIDs.insert(uuid)
        transition(to: subscriptionState)
        flushAll()
    }

    private func handleUnsubscribe(subscriber: String, uuid: UUID) {
        guard subscriberIDs.contains(subscriber) else { return }
        subscriberIDs.remove(subscriber)
        subscribedCharacteristicUUIDs.remove(uuid)
        guard subscriberIDs.isEmpty else {
            transition(to: .connected)
            return
        }
        subscribedCharacteristicUUIDs.removeAll()
        outbound[.data]?.removeAll(keepingCapacity: true)
        outbound[.control]?.removeAll(keepingCapacity: true)
        guard isForeground, adapter.state == .poweredOn else {
            transition(to: .stopped)
            return
        }
        advertiseIfAddressed()
    }

    /// Only meaningful with a subscriber present: one notify channel is a
    /// half-built link, both are a usable one.
    private var subscriptionState: BLEPeripheralLifecycleState {
        subscribedCharacteristicUUIDs.isSuperset(of: [
            NewMotionGATT.phoneToMacDataUUID,
            NewMotionGATT.phoneToMacControlUUID
        ]) ? .ready : .connected
    }

    private func handleWrite(_ write: BLEPeripheralWrite) {
        switch write.characteristic {
        case NewMotionGATT.macToPhoneDataUUID:
            onFrameReceived?(.data, write.data)
        case NewMotionGATT.macToPhoneControlUUID:
            onFrameReceived?(.control, write.data)
        default:
            return
        }
    }

    private func flushAll() {
        flush(channel: .data, characteristic: NewMotionGATT.phoneToMacDataUUID)
        flush(channel: .control, characteristic: NewMotionGATT.phoneToMacControlUUID)
        guard queuedFrameCount == 0, state == .ready else { return }
        onReadyToSend?()
    }

    private func flush(channel: BLETransportChannel, characteristic: UUID) {
        while let first = outbound[channel]?.first {
            guard adapter.updateValue(first, characteristicUUID: characteristic) else { return }
            outbound[channel]?.removeFirst()
        }
    }

    private func transition(to next: BLEPeripheralLifecycleState) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}
