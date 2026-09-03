import Foundation

public enum PointerStreamError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion
    case invalidLength
    case unknownKind
    case emptyFrame
    case tooManyItems
}

public enum PointerStreamKind: UInt8, Equatable, Sendable {
    case pointer = 1
    case scroll = 2
}

public struct PointerStreamItem: Equatable, Sendable {
    public let kind: PointerStreamKind
    public let deltaX: Int16
    public let deltaY: Int16

    public init(kind: PointerStreamKind, deltaX: Int16, deltaY: Int16) {
        self.kind = kind
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

/// Compact BLE cursor frame, encrypted as application type `pointerDelta`.
/// The JSON envelope spends 206 bytes to carry four bytes of movement, which
/// is more than the link can push at finger rate; five bytes per delta is what
/// keeps the radio ahead of the hand.  Several deltas ride in one frame so a
/// backlog costs one packet instead of one packet each.
public struct PointerStreamFrame: Equatable, Sendable {
    public static let magic = Data([0x50, 0x52, 0x50, 0x31]) // PRP1
    public static let version: UInt8 = 1
    public static let headerBytes = 6
    public static let itemBytes = 5
    public static let maximumItems = 32

    public let items: [PointerStreamItem]

    public init(items: [PointerStreamItem]) throws {
        guard !items.isEmpty else { throw PointerStreamError.emptyFrame }
        guard items.count <= Self.maximumItems else { throw PointerStreamError.tooManyItems }
        self.items = items
    }

    public var encodedByteCount: Int { Self.headerBytes + items.count * Self.itemBytes }

    public func encode() -> Data {
        var data = Data(capacity: encodedByteCount)
        data.append(Self.magic)
        data.append(Self.version)
        data.append(UInt8(items.count))
        for item in items {
            data.append(item.kind.rawValue)
            appendInt16(item.deltaX, to: &data)
            appendInt16(item.deltaY, to: &data)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> PointerStreamFrame {
        guard data.count >= headerBytes else { throw PointerStreamError.invalidLength }
        guard data.prefix(4) == magic else { throw PointerStreamError.invalidMagic }
        guard data[data.startIndex + 4] == version else { throw PointerStreamError.unsupportedVersion }
        let count = Int(data[data.startIndex + 5])
        guard count > 0 else { throw PointerStreamError.emptyFrame }
        guard count <= maximumItems else { throw PointerStreamError.tooManyItems }
        guard data.count == headerBytes + count * itemBytes else { throw PointerStreamError.invalidLength }

        let bytes = Array(data)
        var items: [PointerStreamItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            let offset = headerBytes + index * itemBytes
            guard let kind = PointerStreamKind(rawValue: bytes[offset]) else {
                throw PointerStreamError.unknownKind
            }
            items.append(PointerStreamItem(
                kind: kind,
                deltaX: readInt16(bytes, at: offset + 1),
                deltaY: readInt16(bytes, at: offset + 3)
            ))
        }
        return try PointerStreamFrame(items: items)
    }

    private func appendInt16(_ value: Int16, to data: inout Data) {
        let raw = UInt16(bitPattern: value)
        data.append(UInt8(raw >> 8))
        data.append(UInt8(raw & 0xff))
    }

    private static func readInt16(_ bytes: [UInt8], at offset: Int) -> Int16 {
        Int16(bitPattern: (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1]))
    }
}
