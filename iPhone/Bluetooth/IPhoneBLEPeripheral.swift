import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
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
public final class IPhoneBLEPeripheralTransport {
    public let serviceUUID = PhoneRemoteGATT.serviceUUID
    public private(set) var state: BLEPeripheralLifecycleState = .idle
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
    public var onTransportError: ((Error) -> Void)?

    private let adapter: IPhonePeripheralManagerAdapter
    private let localName: String
    private let queueLimit: Int
    private var outbound: [BLETransportChannel: [Data]] = [.data: [], .control: []]
    private var hasPublishedService = false

    public init(
        adapter: IPhonePeripheralManagerAdapter,
        localName: String = "Phone Remote",
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

    /// Advertising is deliberately gated by both foreground state and
    /// powered-on Bluetooth. A background transition immediately removes the
    /// service and clears subscribers/queued frames.
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
        if hasPublishedService {
            transition(to: .advertising)
            adapter.startAdvertising(localName: localName, serviceUUID: serviceUUID)
        } else {
            transition(to: .publishing)
            adapter.publish(serviceUUID: serviceUUID, characteristics: PhoneRemoteGATT.characteristics)
        }
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
        case .data: characteristic = PhoneRemoteGATT.phoneToMacDataUUID
        case .control: characteristic = PhoneRemoteGATT.phoneToMacControlUUID
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
        transition(to: .advertising)
        adapter.startAdvertising(localName: localName, serviceUUID: serviceUUID)
    }

    private func handleAdvertisingStarted(_ error: Error?) {
        guard error != nil else { return }
        IPhoneDebugLog.emit("advertise_error", ["state": "\(state)"])
        // Stay published. A second startAdvertising call can error even when
        // the first beacon is live; tearing down here makes Confirm fail.
    }

    private func handleSubscribe(subscriber: String, uuid: UUID) {
        guard PhoneRemoteGATT.allCharacteristicUUIDs.contains(uuid) else { return }
        subscriberIDs.insert(subscriber)
        subscribedCharacteristicUUIDs.insert(uuid)
        transition(to: subscribedCharacteristicUUIDs.isSuperset(of: [
            PhoneRemoteGATT.phoneToMacDataUUID,
            PhoneRemoteGATT.phoneToMacControlUUID
        ]) ? .ready : .connected)
        flushAll()
    }

    private func handleUnsubscribe(subscriber: String, uuid: UUID) {
        subscriberIDs.remove(subscriber)
        subscribedCharacteristicUUIDs.remove(uuid)
        transition(to: subscriberIDs.isEmpty ? .advertising : .connected)
    }

    private func handleWrite(_ write: BLEPeripheralWrite) {
        switch write.characteristic {
        case PhoneRemoteGATT.macToPhoneDataUUID:
            onFrameReceived?(.data, write.data)
        case PhoneRemoteGATT.macToPhoneControlUUID:
            onFrameReceived?(.control, write.data)
        default:
            return
        }
    }

    private func flushAll() {
        flush(channel: .data, characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        flush(channel: .control, characteristic: PhoneRemoteGATT.phoneToMacControlUUID)
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
