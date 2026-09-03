import Foundation

public enum VoiceStreamError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion
    case unknownCodec
    case invalidLength
}

public enum VoiceStreamCodec: UInt8, Equatable, Sendable {
    case imaAdpcm = 1
}

public struct VoiceStreamFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let start = VoiceStreamFlags(rawValue: 1 << 0)
    public static let end = VoiceStreamFlags(rawValue: 1 << 1)
    /// The speaker threw this utterance away mid-hold. The stream stops here
    /// and nothing it carried may be transcribed or typed.
    public static let cancel = VoiceStreamFlags(rawValue: 1 << 2)
    /// On an `.end` frame: these words are an instruction for editing what is
    /// already in the field, not text to type. On an `.intent` frame: which way
    /// the hold is leaning right now.
    public static let edit = VoiceStreamFlags(rawValue: 1 << 3)
    /// Carries no audio and ends nothing. It says where the finger is hovering
    /// so the Mac can hold its typing and warm the editor before the release.
    public static let intent = VoiceStreamFlags(rawValue: 1 << 4)
}

/// Compact BLE audio frame. Encrypted as application type `audioChunk`.
public struct VoiceStreamFrame: Equatable, Sendable {
    public static let magic = Data([0x50, 0x52, 0x41, 0x31]) // PRA1
    public static let version: UInt8 = 1
    public static let headerBytes = 32
    public static let maximumPayloadBytes = 2_048

    public let flags: VoiceStreamFlags
    public let codec: VoiceStreamCodec
    public let streamID: SessionID
    public let sequence: UInt32
    public let sampleCount: UInt16
    public let payload: Data

    public var isStart: Bool { flags.contains(.start) }
    public var isEnd: Bool { flags.contains(.end) }
    public var isCancel: Bool { flags.contains(.cancel) }
    public var isEdit: Bool { flags.contains(.edit) }
    public var isIntent: Bool { flags.contains(.intent) }

    public init(
        flags: VoiceStreamFlags,
        codec: VoiceStreamCodec = .imaAdpcm,
        streamID: SessionID,
        sequence: UInt32,
        sampleCount: UInt16,
        payload: Data
    ) throws {
        guard payload.count <= Self.maximumPayloadBytes else {
            throw VoiceStreamError.invalidLength
        }
        self.flags = flags
        self.codec = codec
        self.streamID = streamID
        self.sequence = sequence
        self.sampleCount = sampleCount
        self.payload = payload
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.headerBytes + payload.count)
        data.append(Self.magic)
        data.append(Self.version)
        data.append(flags.rawValue)
        data.append(codec.rawValue)
        data.append(0)
        data.append(contentsOf: streamID.bytes)
        appendUInt32(sequence, to: &data)
        appendUInt16(sampleCount, to: &data)
        appendUInt16(UInt16(payload.count), to: &data)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> VoiceStreamFrame {
        guard data.count >= headerBytes else { throw VoiceStreamError.invalidLength }
        guard data.prefix(4) == magic else { throw VoiceStreamError.invalidMagic }
        guard data[4] == version else { throw VoiceStreamError.unsupportedVersion }
        let flags = VoiceStreamFlags(rawValue: data[5])
        guard let codec = VoiceStreamCodec(rawValue: data[6]) else {
            throw VoiceStreamError.unknownCodec
        }
        let streamID = try SessionID(bytes: Array(data[8..<24]))
        let sequence = readUInt32(data, at: 24)
        let sampleCount = readUInt16(data, at: 28)
        let payloadLength = Int(readUInt16(data, at: 30))
        guard payloadLength <= maximumPayloadBytes,
              data.count == headerBytes + payloadLength else {
            throw VoiceStreamError.invalidLength
        }
        return try VoiceStreamFrame(
            flags: flags,
            codec: codec,
            streamID: streamID,
            sequence: sequence,
            sampleCount: sampleCount,
            payload: Data(data.suffix(payloadLength))
        )
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
