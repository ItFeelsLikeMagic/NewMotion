#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Thin Core Bluetooth bridge. The transport state machine intentionally
/// depends only on `IPhonePeripheralManagerAdapter`, making this class easy to
/// replace with a fake in unit tests.
public final class CoreBluetoothPeripheralManagerAdapter: NSObject, IPhonePeripheralManagerAdapter {
    public private(set) var state: BLEPeripheralManagerState = .unknown
    public private(set) var maximumUpdateValueLength: Int = BLEFramingLimits.minimumValueLength
    public var onStateChange: ((BLEPeripheralManagerState) -> Void)?
    public var onServicePublished: ((UUID, Error?) -> Void)?
    public var onSubscribe: ((String, UUID) -> Void)?
    public var onUnsubscribe: ((String, UUID) -> Void)?
    public var onWrite: ((BLEPeripheralWrite) -> Void)?
    public var onReadyToUpdateSubscribers: (() -> Void)?
    public var onAdvertisingStarted: ((Error?) -> Void)?

    private let callbackQueue: DispatchQueue
    private var manager: CBPeripheralManager!
    private var characteristics: [UUID: CBMutableCharacteristic] = [:]
    private var subscriberIDs: [ObjectIdentifier: String] = [:]

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: callbackQueue)
    }

    public func publish(serviceUUID: UUID, characteristics definitions: [BLECharacteristicDefinition]) {
        guard state == .poweredOn else { return }
        let mutableCharacteristics = definitions.map { definition -> CBMutableCharacteristic in
            let properties = cbProperties(definition.properties)
            let permissions: CBAttributePermissions = definition.direction == .macToPhone
                ? [.writeable]
                : [.readable]
            let characteristic = CBMutableCharacteristic(
                type: CBUUID(string: definition.uuid.uuidString),
                properties: properties,
                value: nil,
                permissions: permissions
            )
            characteristics[definition.uuid] = characteristic
            return characteristic
        }
        let service = CBMutableService(type: CBUUID(string: serviceUUID.uuidString), primary: true)
        service.characteristics = mutableCharacteristics
        manager.add(service)
    }

    public func startAdvertising(localName: String, serviceUUID: UUID) {
        guard state == .poweredOn else { return }
        manager.startAdvertising(Self.advertisementData(localName: localName, serviceUUID: serviceUUID))
    }

    /// Core Bluetooth rejects Foundation `UUID` values here. The advertised
    /// service must be a `CBUUID` or a Mac scanning for this service never
    /// sees the phone.
    static func advertisementData(localName: String, serviceUUID: UUID) -> [String: Any] {
        [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: serviceUUID)]
        ]
    }

    public func stopAdvertising() {
        guard state == .poweredOn else { return }
        manager.stopAdvertising()
    }

    public func removeAllServices() {
        if state == .poweredOn {
            manager.removeAllServices()
        }
        characteristics.removeAll()
        subscriberIDs.removeAll()
    }

    @discardableResult
    public func updateValue(_ data: Data, characteristicUUID: UUID) -> Bool {
        guard let characteristic = characteristics[characteristicUUID] else { return false }
        return manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
    }

    private func mapState(_ state: CBManagerState) -> BLEPeripheralManagerState {
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        @unknown default: return .unknown
        }
    }

    private func cbProperties(_ properties: BLECharacteristicProperties) -> CBCharacteristicProperties {
        var result: CBCharacteristicProperties = []
        if properties.contains(.read) { result.insert(.read) }
        if properties.contains(.write) { result.insert(.write) }
        if properties.contains(.writeWithoutResponse) { result.insert(.writeWithoutResponse) }
        if properties.contains(.notify) { result.insert(.notify) }
        return result
    }
}

extension CoreBluetoothPeripheralManagerAdapter: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        state = mapState(peripheral.state)
        // The negotiated size arrives with the central's subscription; it only
        // goes stale when the radio is no longer powered on.
        if state != .poweredOn {
            maximumUpdateValueLength = BLEFramingLimits.minimumValueLength
        }
        onStateChange?(state)
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        onAdvertisingStarted?(error)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        onServicePublished?(UUID(uuidString: service.uuid.uuidString) ?? UUID(), error)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let id = subscriberIDs[ObjectIdentifier(central)] ?? {
            let generated = UUID().uuidString
            subscriberIDs[ObjectIdentifier(central)] = generated
            return generated
        }()
        maximumUpdateValueLength = max(BLEFramingLimits.minimumValueLength, central.maximumUpdateValueLength)
        onSubscribe?(id, UUID(uuidString: characteristic.uuid.uuidString) ?? UUID())
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let id = subscriberIDs[ObjectIdentifier(central)] ?? ""
        onUnsubscribe?(id, UUID(uuidString: characteristic.uuid.uuidString) ?? UUID())
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let id = subscriberIDs[ObjectIdentifier(request.central)] ?? ""
            if let value = request.value {
                onWrite?(BLEPeripheralWrite(
                    characteristic: UUID(uuidString: request.characteristic.uuid.uuidString) ?? UUID(),
                    data: value,
                    subscriberID: id
                ))
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        onReadyToUpdateSubscribers?()
    }
}
#endif
