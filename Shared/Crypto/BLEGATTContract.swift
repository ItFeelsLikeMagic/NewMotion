import Foundation

public struct BLECharacteristicProperties: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let read = BLECharacteristicProperties(rawValue: 1 << 0)
    public static let write = BLECharacteristicProperties(rawValue: 1 << 1)
    public static let writeWithoutResponse = BLECharacteristicProperties(rawValue: 1 << 2)
    public static let notify = BLECharacteristicProperties(rawValue: 1 << 3)
}

public enum BLECharacteristicDirection: Equatable, Sendable {
    case phoneToMac
    case macToPhone
}

public struct BLECharacteristicDefinition: Equatable, Sendable {
    public let uuid: UUID
    public let direction: BLECharacteristicDirection
    public let properties: BLECharacteristicProperties

    public init(uuid: UUID, direction: BLECharacteristicDirection, properties: BLECharacteristicProperties) {
        self.uuid = uuid
        self.direction = direction
        self.properties = properties
    }
}

public enum PhoneRemoteGATT {
    public static let serviceUUID = UUID(uuidString: "A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1000")!
    public static let phoneToMacDataUUID = UUID(uuidString: "A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1010")!
    public static let macToPhoneDataUUID = UUID(uuidString: "A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1011")!
    public static let phoneToMacControlUUID = UUID(uuidString: "A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1020")!
    public static let macToPhoneControlUUID = UUID(uuidString: "A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1021")!

    public static let characteristics: [BLECharacteristicDefinition] = [
        BLECharacteristicDefinition(
            uuid: phoneToMacDataUUID,
            direction: .phoneToMac,
            properties: [.read, .notify]
        ),
        BLECharacteristicDefinition(
            uuid: macToPhoneDataUUID,
            direction: .macToPhone,
            properties: [.write, .writeWithoutResponse]
        ),
        BLECharacteristicDefinition(
            uuid: phoneToMacControlUUID,
            direction: .phoneToMac,
            properties: [.read, .notify]
        ),
        BLECharacteristicDefinition(
            uuid: macToPhoneControlUUID,
            direction: .macToPhone,
            properties: [.write, .writeWithoutResponse]
        )
    ]

    public static var allCharacteristicUUIDs: Set<UUID> { Set(characteristics.map(\.uuid)) }
}

public enum BLEPeripheralManagerState: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public enum BLEPeripheralLifecycleState: Equatable, Sendable {
    case idle
    case waitingForBluetooth
    case publishing
    case advertising
    case connected
    case ready
    case stopped
}

public enum BLECentralLifecycleState: Equatable, Sendable {
    case idle
    case waitingForBluetooth
    case scanning
    case connecting
    case discovering
    case subscribing
    case ready
    case disconnected
    case stopped
}

public enum BLETransportChannel: Equatable, Sendable {
    case data
    case control
}
