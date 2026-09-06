import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
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
    var onServicesInvalidated: ((UUID, Set<UUID>) -> Void)? { get set }
    var onCharacteristicsDiscovered: ((UUID, UUID, Set<UUID>, Error?) -> Void)? { get set }
    var onNotificationState: ((UUID, UUID, Bool, Error?) -> Void)? { get set }
    var onValue: ((UUID, UUID, Data?, Error?) -> Void)? { get set }
    var onReadyToWriteWithoutResponse: (() -> Void)? { get set }
    var onWriteComplete: ((Error?) -> Void)? { get set }

    func scan(for serviceUUIDs: [UUID])
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
