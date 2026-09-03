import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// A central adapter that never touches Core Bluetooth. The macOS test bundle
/// launches the real app as its test host; constructing `CBCentralManager`
/// there raises the system Bluetooth prompt on every unsigned rebuild, so the
/// host uses this adapter instead and reports Bluetooth as unavailable.
public final class InertCentralManagerAdapter: MacCentralManagerAdapter {
    public let state: BLEPeripheralManagerState = .unsupported
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

    public init() {}

    public func scan(for serviceUUID: UUID) {}
    public func stopScan() {}
    public func connectedPeripherals(for serviceUUID: UUID) -> [BLEDiscoveredPeripheral] { [] }
    public func connect(peripheralID: UUID) {}
    public func cancelConnection(peripheralID: UUID) {}
    public func discoverServices(peripheralID: UUID, serviceUUID: UUID) {}
    public func discoverCharacteristics(peripheralID: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID]) {}
    public func subscribe(peripheralID: UUID, characteristicUUID: UUID) {}
    @discardableResult
    public func write(_ data: Data, peripheralID: UUID, characteristicUUID: UUID, type: BLEWriteType) -> Bool { false }
    public func maximumWriteValueLength(peripheralID: UUID, characteristicUUID: UUID) -> Int {
        BLEFramingLimits.minimumValueLength
    }
}
