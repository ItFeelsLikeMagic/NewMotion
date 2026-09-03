import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

public struct BLEDiscoveredPeripheral: Equatable {
    public let identifier: UUID
    public let name: String?

    public init(identifier: UUID, name: String?) {
        self.identifier = identifier
        self.name = name
    }
}

public enum BLEWriteType: Equatable {
    case withoutResponse
    case withResponse
}

public protocol MacCentralManagerAdapter: AnyObject {
    var state: BLEPeripheralManagerState { get }
    var onStateChange: ((BLEPeripheralManagerState) -> Void)? { get set }
    var onDiscoverPeripheral: ((BLEDiscoveredPeripheral) -> Void)? { get set }
    var onConnected: ((UUID) -> Void)? { get set }
    var onConnectionFailed: ((UUID, Error?) -> Void)? { get set }
    var onDisconnected: ((UUID, Error?) -> Void)? { get set }
    var onServicesDiscovered: ((UUID, Set<UUID>, Error?) -> Void)? { get set }
    var onCharacteristicsDiscovered: ((UUID, UUID, Set<UUID>, Error?) -> Void)? { get set }
    var onNotificationState: ((UUID, UUID, Bool, Error?) -> Void)? { get set }
    var onValue: ((UUID, UUID, Data?, Error?) -> Void)? { get set }
    var onReadyToWriteWithoutResponse: (() -> Void)? { get set }
    var onWriteComplete: ((Error?) -> Void)? { get set }

    func scan(for serviceUUID: UUID)
    func stopScan()
    func connectedPeripherals(for serviceUUID: UUID) -> [BLEDiscoveredPeripheral]
    func connect(peripheralID: UUID)
    func cancelConnection(peripheralID: UUID)
    func discoverServices(peripheralID: UUID, serviceUUID: UUID)
    func discoverCharacteristics(peripheralID: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID])
    func subscribe(peripheralID: UUID, characteristicUUID: UUID)
    @discardableResult
    func write(_ data: Data, peripheralID: UUID, characteristicUUID: UUID, type: BLEWriteType) -> Bool
    func maximumWriteValueLength(peripheralID: UUID, characteristicUUID: UUID) -> Int
}

public final class MacBLECentralTransport {
    public let serviceUUID = PhoneRemoteGATT.serviceUUID
    public private(set) var state: BLECentralLifecycleState = .idle
    public private(set) var connectedPeripheral: BLEDiscoveredPeripheral?
    /// The peripheral currently being connected or already ready. This is a
    /// presentation-safe snapshot for status UI; authentication still has to
    /// complete before the Mac treats the phone as paired.
    public var visiblePeripheral: BLEDiscoveredPeripheral? {
        connectedPeripheral ?? pendingPeripheral
    }
    public private(set) var discoveredCharacteristics: Set<UUID> = []
    public private(set) var maximumWriteValueLength = BLEFramingLimits.minimumValueLength

    public var onStateChange: ((BLECentralLifecycleState) -> Void)?
    public var onFrameReceived: ((BLETransportChannel, Data) -> Void)?
    public var onTransportError: ((Error) -> Void)?
    public var onStatus: ((String) -> Void)?

    private let adapter: MacCentralManagerAdapter
    private let connectionTimeout: TimeInterval
    private let now: () -> Date
    private var pendingPeripheral: BLEDiscoveredPeripheral?
    private var pendingDeadline: Date?
    private var pendingSubscriptions: Set<UUID> = []
    private var subscribed: Set<UUID> = []
    private var writeQueue: [(Data, UUID, BLEWriteType)] = []
    private var reliableWriteInFlight = false
    private let writeQueueLimit: Int

    public init(
        adapter: MacCentralManagerAdapter,
        connectionTimeout: TimeInterval = 10,
        writeQueueLimit: Int = BLEFramingLimits.maximumQueuedFrames,
        now: @escaping () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.connectionTimeout = max(1, connectionTimeout)
        self.writeQueueLimit = max(1, writeQueueLimit)
        self.now = now
        adapter.onStateChange = { [weak self] state in self?.handleState(state) }
        adapter.onDiscoverPeripheral = { [weak self] peripheral in self?.handleDiscover(peripheral) }
        adapter.onConnected = { [weak self] peripheralID in self?.handleConnected(peripheralID) }
        adapter.onConnectionFailed = { [weak self] peripheralID, error in self?.handleConnectionFailure(peripheralID, error: error) }
        adapter.onDisconnected = { [weak self] peripheralID, error in self?.handleDisconnected(peripheralID, error: error) }
        adapter.onServicesDiscovered = { [weak self] peripheralID, services, error in self?.handleServices(peripheralID, services: services, error: error) }
        adapter.onCharacteristicsDiscovered = { [weak self] peripheralID, serviceUUID, characteristics, error in self?.handleCharacteristics(peripheralID, serviceUUID: serviceUUID, characteristics: characteristics, error: error) }
        adapter.onNotificationState = { [weak self] peripheralID, characteristicUUID, enabled, error in self?.handleNotification(peripheralID, characteristicUUID: characteristicUUID, enabled: enabled, error: error) }
        adapter.onValue = { [weak self] peripheralID, characteristicUUID, data, error in self?.handleValue(peripheralID, characteristicUUID: characteristicUUID, data: data, error: error) }
        adapter.onReadyToWriteWithoutResponse = { [weak self] in self?.flushWrites() }
        adapter.onWriteComplete = { [weak self] error in self?.handleWriteComplete(error) }
        handleState(adapter.state)
    }

    public func start() {
        guard adapter.state == .poweredOn else {
            transition(to: .waitingForBluetooth)
            return
        }
        pendingPeripheral = nil
        pendingDeadline = nil
        connectedPeripheral = nil
        discoveredCharacteristics.removeAll()
        subscribed.removeAll()
        transition(to: .scanning)
        adapter.scan(for: serviceUUID)
        adoptSystemConnectedPeripheral()
    }

    public func stop() {
        adapter.stopScan()
        if let peripheral = connectedPeripheral ?? pendingPeripheral {
            adapter.cancelConnection(peripheralID: peripheral.identifier)
        }
        clearConnection()
        transition(to: .stopped)
    }

    /// Called about once a second. Enforces the connection timeout, and while
    /// scanning keeps polling for a phone the system already holds a link to.
    public func tick() {
        if let deadline = pendingDeadline, now() >= deadline {
            failLink(error: nil, resumeScan: true)
            return
        }
        if state == .scanning { adoptSystemConnectedPeripheral() }
    }

    /// macOS keeps the BLE link to a paired iPhone alive after the phone app
    /// quits, and a peripheral the system is connected to never shows up in a
    /// scan; it only appears here once the relaunched app republishes the
    /// service.
    private func adoptSystemConnectedPeripheral() {
        for peripheral in adapter.connectedPeripherals(for: serviceUUID) {
            handleDiscover(peripheral)
            if state != .scanning { break }
        }
    }

    @discardableResult
    public func send(_ data: Data, on channel: BLETransportChannel, reliable: Bool = false) -> Bool {
        guard state == .ready || state == .subscribing else { return false }
        let peripheral = connectedPeripheral ?? pendingPeripheral
        guard let peripheral, !data.isEmpty else { return false }
        let characteristic: UUID
        switch channel {
        case .data: characteristic = PhoneRemoteGATT.macToPhoneDataUUID
        case .control: characteristic = PhoneRemoteGATT.macToPhoneControlUUID
        }
        let type: BLEWriteType = reliable ? .withResponse : .withoutResponse
        if type == .withResponse, reliableWriteInFlight {
            return enqueue(data, characteristic: characteristic, type: type)
        }
        if type == .withResponse { reliableWriteInFlight = true }
        if adapter.write(data, peripheralID: peripheral.identifier, characteristicUUID: characteristic, type: type) {
            return true
        }
        if type == .withResponse { reliableWriteInFlight = false }
        return enqueue(data, characteristic: characteristic, type: type)
    }

    public var queuedWriteCount: Int { writeQueue.count }

    private func handleState(_ managerState: BLEPeripheralManagerState) {
        switch managerState {
        case .poweredOn:
            if state == .waitingForBluetooth { start() }
        case .unknown, .resetting, .unsupported, .unauthorized, .poweredOff:
            adapter.stopScan()
            if let peripheral = connectedPeripheral ?? pendingPeripheral {
                adapter.cancelConnection(peripheralID: peripheral.identifier)
            }
            clearConnection()
            transition(to: .waitingForBluetooth)
        }
    }

    private func handleDiscover(_ peripheral: BLEDiscoveredPeripheral) {
        guard state == .scanning else { return }
        adapter.stopScan()
        pendingPeripheral = peripheral
        pendingDeadline = now().addingTimeInterval(connectionTimeout)
        transition(to: .connecting)
        adapter.connect(peripheralID: peripheral.identifier)
    }

    private func handleConnected(_ peripheralID: UUID) {
        guard pendingPeripheral?.identifier == peripheralID else { return }
        pendingDeadline = now().addingTimeInterval(connectionTimeout)
        transition(to: .discovering)
        adapter.discoverServices(peripheralID: peripheralID, serviceUUID: serviceUUID)
    }

    private func handleConnectionFailure(_ peripheralID: UUID, error: Error?) {
        guard pendingPeripheral?.identifier == peripheralID else { return }
        failLink(error: error, resumeScan: true)
    }

    private func handleDisconnected(_ peripheralID: UUID, error: Error?) {
        guard connectedPeripheral?.identifier == peripheralID || pendingPeripheral?.identifier == peripheralID else { return }
        // Always rescan so a trusted phone can reconnect without a new QR.
        failLink(error: error, resumeScan: true)
    }

    private func handleServices(_ peripheralID: UUID, services: Set<UUID>, error: Error?) {
        guard state == .discovering, pendingPeripheral?.identifier == peripheralID else { return }
        guard error == nil, services.contains(serviceUUID) else {
            failLink(error: error ?? BLEFramingError.unknownFrameKind, resumeScan: true)
            return
        }
        transition(to: .subscribing)
        adapter.discoverCharacteristics(
            peripheralID: peripheralID,
            serviceUUID: serviceUUID,
            characteristicUUIDs: Array(PhoneRemoteGATT.allCharacteristicUUIDs)
        )
    }

    private func handleCharacteristics(_ peripheralID: UUID, serviceUUID: UUID, characteristics: Set<UUID>, error: Error?) {
        guard state == .subscribing, pendingPeripheral?.identifier == peripheralID, serviceUUID == self.serviceUUID else { return }
        guard error == nil, characteristics.isSuperset(of: PhoneRemoteGATT.allCharacteristicUUIDs) else {
            failLink(error: error ?? BLEFramingError.malformedHeader, resumeScan: true)
            return
        }
        discoveredCharacteristics = characteristics
        connectedPeripheral = pendingPeripheral
        pendingSubscriptions = [PhoneRemoteGATT.phoneToMacDataUUID, PhoneRemoteGATT.phoneToMacControlUUID]
        subscribed.removeAll()
        for characteristic in pendingSubscriptions {
            adapter.subscribe(peripheralID: peripheralID, characteristicUUID: characteristic)
        }
    }

    private func handleNotification(_ peripheralID: UUID, characteristicUUID: UUID, enabled: Bool, error: Error?) {
        guard state == .subscribing, pendingPeripheral?.identifier == peripheralID else { return }
        guard error == nil, enabled, pendingSubscriptions.contains(characteristicUUID) else {
            failLink(error: error ?? BLEFramingError.invalidFlags, resumeScan: true)
            return
        }
        subscribed.insert(characteristicUUID)
        if subscribed == pendingSubscriptions {
            connectedPeripheral = pendingPeripheral
            pendingPeripheral = nil
            pendingDeadline = nil
            maximumWriteValueLength = max(
                BLEFramingLimits.minimumValueLength,
                adapter.maximumWriteValueLength(peripheralID: peripheralID, characteristicUUID: PhoneRemoteGATT.macToPhoneDataUUID)
            )
            transition(to: .ready)
            flushWrites()
        }
    }

    private func handleValue(_ peripheralID: UUID, characteristicUUID: UUID, data: Data?, error: Error?) {
        guard connectedPeripheral?.identifier == peripheralID else { return }
        if let error {
            onTransportError?(error)
            return
        }
        guard let data else { return }
        switch characteristicUUID {
        case PhoneRemoteGATT.phoneToMacDataUUID: onFrameReceived?(.data, data)
        case PhoneRemoteGATT.phoneToMacControlUUID: onFrameReceived?(.control, data)
        default: break
        }
    }

    private func enqueue(_ data: Data, characteristic: UUID, type: BLEWriteType) -> Bool {
        guard writeQueue.count < writeQueueLimit else {
            onTransportError?(BLEFramingError.queueFull)
            return false
        }
        writeQueue.append((data, characteristic, type))
        return true
    }

    private func handleWriteComplete(_ error: Error?) {
        reliableWriteInFlight = false
        if let error {
            onTransportError?(error)
            return
        }
        flushWrites()
    }

    private func flushWrites() {
        guard let peripheral = connectedPeripheral else { return }
        while let first = writeQueue.first {
            if first.2 == .withResponse, reliableWriteInFlight { return }
            if first.2 == .withResponse { reliableWriteInFlight = true }
            guard adapter.write(first.0, peripheralID: peripheral.identifier, characteristicUUID: first.1, type: first.2) else {
                if first.2 == .withResponse { reliableWriteInFlight = false }
                return
            }
            writeQueue.removeFirst()
            if first.2 == .withResponse { return }
        }
    }

    private func failLink(error: Error?, resumeScan: Bool) {
        if let error { onTransportError?(error) }
        adapter.stopScan()
        if let peripheral = connectedPeripheral ?? pendingPeripheral {
            adapter.cancelConnection(peripheralID: peripheral.identifier)
        }
        clearConnection()
        if resumeScan, adapter.state == .poweredOn {
            start()
        } else {
            transition(to: .disconnected)
        }
    }

    private func clearConnection() {
        pendingPeripheral = nil
        pendingDeadline = nil
        connectedPeripheral = nil
        discoveredCharacteristics.removeAll()
        pendingSubscriptions.removeAll()
        subscribed.removeAll()
        writeQueue.removeAll(keepingCapacity: true)
        reliableWriteInFlight = false
    }

    private func transition(to next: BLECentralLifecycleState) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
        onStatus?(String(describing: next))
    }
}
