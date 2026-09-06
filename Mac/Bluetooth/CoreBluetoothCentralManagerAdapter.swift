#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
#endif

public final class CoreBluetoothCentralManagerAdapter: NSObject, MacCentralManagerAdapter {
    public private(set) var state: BLEPeripheralManagerState = .unknown
    public var onStateChange: ((BLEPeripheralManagerState) -> Void)?
    public var onDiscoverPeripheral: ((BLEDiscoveredPeripheral) -> Void)?
    public var onConnected: ((UUID) -> Void)?
    public var onConnectionFailed: ((UUID, Error?) -> Void)?
    public var onDisconnected: ((UUID, Error?) -> Void)?
    public var onServicesDiscovered: ((UUID, Set<UUID>, Error?) -> Void)?
    public var onServicesInvalidated: ((UUID, Set<UUID>) -> Void)?
    public var onCharacteristicsDiscovered: ((UUID, UUID, Set<UUID>, Error?) -> Void)?
    public var onNotificationState: ((UUID, UUID, Bool, Error?) -> Void)?
    public var onValue: ((UUID, UUID, Data?, Error?) -> Void)?
    public var onReadyToWriteWithoutResponse: (() -> Void)?
    public var onWriteComplete: ((Error?) -> Void)?

    private let callbackQueue: DispatchQueue
    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var services: [UUID: [UUID: CBService]] = [:]
    private var characteristics: [UUID: [UUID: CBCharacteristic]] = [:]

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        super.init()
        manager = CBCentralManager(delegate: self, queue: callbackQueue)
    }

    public func scan(for serviceUUID: UUID) {
        guard state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: [CBUUID(string: serviceUUID.uuidString)], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        guard state == .poweredOn else { return }
        manager.stopScan()
    }

    public func connectedPeripherals(for serviceUUID: UUID) -> [BLEDiscoveredPeripheral] {
        let found = manager.retrieveConnectedPeripherals(
            withServices: [CBUUID(string: serviceUUID.uuidString)]
        )
        return found.map { peripheral in
            peripherals[peripheral.identifier] = peripheral
            return BLEDiscoveredPeripheral(identifier: peripheral.identifier, name: peripheral.name)
        }
    }

    public func connect(peripheralID: UUID) {
        guard let peripheral = peripherals[peripheralID] else { return }
        manager.connect(peripheral, options: nil)
    }

    public func cancelConnection(peripheralID: UUID) {
        guard let peripheral = peripherals[peripheralID] else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    public func discoverServices(peripheralID: UUID, serviceUUID: UUID) {
        peripherals[peripheralID]?.discoverServices([CBUUID(string: serviceUUID.uuidString)])
    }

    public func discoverCharacteristics(peripheralID: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID]) {
        guard let service = services[peripheralID]?[serviceUUID] else { return }
        peripherals[peripheralID]?.discoverCharacteristics(
            characteristicUUIDs.map { CBUUID(string: $0.uuidString) },
            for: service
        )
    }

    public func subscribe(peripheralID: UUID, characteristicUUID: UUID) {
        guard let characteristic = characteristics[peripheralID]?[characteristicUUID], let peripheral = peripherals[peripheralID] else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    @discardableResult
    public func write(_ data: Data, peripheralID: UUID, characteristicUUID: UUID, type: BLEWriteType) -> Bool {
        guard let characteristic = characteristics[peripheralID]?[characteristicUUID], let peripheral = peripherals[peripheralID] else { return false }
        let cbType: CBCharacteristicWriteType = type == .withResponse ? .withResponse : .withoutResponse
        if cbType == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return false }
        peripheral.writeValue(data, for: characteristic, type: cbType)
        return true
    }

    public func maximumWriteValueLength(peripheralID: UUID, characteristicUUID: UUID) -> Int {
        guard let peripheral = peripherals[peripheralID], characteristics[peripheralID]?[characteristicUUID] != nil else {
            return BLEFramingLimits.minimumValueLength
        }
        return max(BLEFramingLimits.minimumValueLength, peripheral.maximumWriteValueLength(for: .withoutResponse))
    }
}

extension CoreBluetoothCentralManagerAdapter: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown: state = .unknown
        case .resetting: state = .resetting
        case .unsupported: state = .unsupported
        case .unauthorized: state = .unauthorized
        case .poweredOff: state = .poweredOff
        case .poweredOn: state = .poweredOn
        @unknown default: state = .unknown
        }
        onStateChange?(state)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        onDiscoverPeripheral?(BLEDiscoveredPeripheral(
            identifier: peripheral.identifier,
            name: advertisedName ?? peripheral.name
        ))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        onConnected?(peripheral.identifier)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onConnectionFailed?(peripheral.identifier, error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onDisconnected?(peripheral.identifier, error)
    }
}

extension CoreBluetoothCentralManagerAdapter: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // A peripheral may legitimately publish the same service UUID twice: two
        // apps on one phone offering the same service put two entries in its
        // GATT table. Building the map with unique keys traps on that, which
        // crashes the Mac app a second after it connects. Keep the last.
        let serviceMap = Dictionary(
            (peripheral.services ?? []).compactMap { service -> (UUID, CBService)? in
                guard let uuid = UUID(uuidString: service.uuid.uuidString) else { return nil }
                return (uuid, service)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        services[peripheral.identifier] = serviceMap
        // Handles from the previous discovery belong to services that are gone.
        characteristics[peripheral.identifier] = [:]
        onServicesDiscovered?(peripheral.identifier, Set(serviceMap.keys), error)
    }

    /// Fires when the phone republishes its GATT table. Everything cached for
    /// this peripheral is now a dangling handle.
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let invalidated = Set(invalidatedServices.compactMap { UUID(uuidString: $0.uuid.uuidString) })
        for uuid in invalidated { services[peripheral.identifier]?[uuid] = nil }
        characteristics[peripheral.identifier] = [:]
        onServicesInvalidated?(peripheral.identifier, invalidated)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        var map = characteristics[peripheral.identifier] ?? [:]
        for characteristic in service.characteristics ?? [] {
            if let uuid = UUID(uuidString: characteristic.uuid.uuidString) { map[uuid] = characteristic }
        }
        characteristics[peripheral.identifier] = map
        let serviceUUID = UUID(uuidString: service.uuid.uuidString) ?? UUID()
        let characteristicUUIDs = Set((service.characteristics ?? []).compactMap { UUID(uuidString: $0.uuid.uuidString) })
        onCharacteristicsDiscovered?(peripheral.identifier, serviceUUID, characteristicUUIDs, error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let uuid = UUID(uuidString: characteristic.uuid.uuidString) else { return }
        onNotificationState?(peripheral.identifier, uuid, characteristic.isNotifying, error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let uuid = UUID(uuidString: characteristic.uuid.uuidString) else { return }
        onValue?(peripheral.identifier, uuid, characteristic.value, error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        onWriteComplete?(error)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        onReadyToWriteWithoutResponse?()
    }
}
#endif
