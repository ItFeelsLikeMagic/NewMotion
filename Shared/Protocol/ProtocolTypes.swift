// Copyright © 2026 PhoneRemote contributors.
//
// Transport-neutral protocol models. Foundation is used only for audio PCM
// base64 on the wire; the models still contain no Core Bluetooth types.

import Foundation

/// The protocol versions understood by this prototype.
public enum ProtocolVersion: UInt8, Codable, Equatable, Sendable {
    case v1 = 1
}

/// The delivery semantics expected by the receiver for a message type.
public enum DeliveryClass: String, Codable, Equatable, Sendable {
    case reliable
    case unreliable
}

/// The complete MVP message vocabulary. Raw values are part of the wire
/// contract and must not be reused for a different meaning.
public enum MessageType: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case heartbeat = 1
    case pointerDelta = 2
    case scrollDelta = 3
    case mouseButton = 4
    case textInput = 5
    case hotkey = 6
    case motionPointerDelta = 7
    case audioChunk = 8
    case acknowledgement = 9
    case connectionStatus = 10
    case error = 11
    case ping = 12
    case pong = 13
    case mouseDoubleClick = 14
    case appSwitcher = 15

    public var deliveryClass: DeliveryClass {
        switch self {
        case .heartbeat, .pointerDelta, .scrollDelta, .motionPointerDelta, .audioChunk:
            return .unreliable
        case .mouseButton, .mouseDoubleClick, .textInput, .hotkey, .appSwitcher,
             .acknowledgement, .connectionStatus, .error, .ping, .pong:
            return .reliable
        }
    }
}

/// The 16-byte identifier for a protocol session or an audio stream.
public struct SessionID: Codable, Equatable, Hashable, Sendable {
    public static let byteCount = 16

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw ProtocolError.invalidField("session_id_length")
        }
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let count = container.count, count == Self.byteCount else {
            throw ProtocolError.invalidField("session_id_length")
        }

        var result: [UInt8] = []
        result.reserveCapacity(Self.byteCount)
        for _ in 0..<Self.byteCount {
            result.append(try container.decode(UInt8.self))
        }
        self.bytes = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for byte in bytes {
            try container.encode(byte)
        }
    }
}

/// A bounded byte sequence used for text UTF-8 and audio PCM. The bound is
/// checked from the decoder's declared array count before reserving storage.
public struct ProtocolBytes: Codable, Equatable, Sendable {
    /// JSON envelope overhead plus a bounded raw-audio chunk must fit inside
    /// the 8192-byte envelope ceiling; 2048 bytes is a 64 ms mono-PCM chunk.
    public static let maximumCount = 2_048

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count <= Self.maximumCount else {
            throw ProtocolError.fieldTooLarge("bytes", actual: bytes.count, limit: Self.maximumCount)
        }
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let count = container.count else {
            throw ProtocolError.invalidField("bytes_not_array")
        }
        guard count <= Self.maximumCount else {
            throw ProtocolError.fieldTooLarge("bytes", actual: count, limit: Self.maximumCount)
        }

        var result: [UInt8] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try container.decode(UInt8.self))
        }
        self.bytes = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for byte in bytes {
            try container.encode(byte)
        }
    }
}

/// The buttons a heartbeat reports as held, as they sit on the wire.
///
/// Which bit means which button is decided here and nowhere else.  The two
/// ends would not fail loudly if they disagreed: one would quietly release, or
/// press, a button the other never meant.
public struct HeldButtons: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The only place a button becomes a bit.  A new button needs no other
    /// change, here or on either side of the link.
    public init(_ button: MouseButton) {
        self.init(rawValue: 1 << (button.rawValue - 1))
    }

    public static let left = HeldButtons(MouseButton.left)
    public static let right = HeldButtons(MouseButton.right)

    /// Every bit the protocol defines.  A byte with anything else set is
    /// malformed rather than merely unknown.
    public static let all = MouseButton.allCases.reduce(into: HeldButtons()) {
        $0.insert(HeldButtons($1))
    }
}

/// The modifier keys a heartbeat can report as held.  The protocol carries no
/// key codes, so the wire needs its own spelling; each platform maps its own
/// modifier type onto these in a single table.
public enum HeldModifier: UInt8, CaseIterable, Equatable, Sendable {
    case command = 0
    case option = 1
    case control = 2
    case shift = 3
}

/// The modifier half of the same idea.  See `HeldButtons`.
public struct HeldModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public init(_ modifier: HeldModifier) {
        self.init(rawValue: 1 << modifier.rawValue)
    }

    public static let command = HeldModifiers(HeldModifier.command)
    public static let option = HeldModifiers(HeldModifier.option)
    public static let control = HeldModifiers(HeldModifier.control)
    public static let shift = HeldModifiers(HeldModifier.shift)

    public static let all = HeldModifier.allCases.reduce(into: HeldModifiers()) {
        $0.insert(HeldModifiers($1))
    }
}

/// A periodic "still here, and this is what I am holding down" message.
///
/// It does two jobs, and the second is the one worth remembering.  It proves
/// the sender is alive, so the receiver can let go of held input when it stops
/// arriving.  It also carries the whole held set rather than a change to it,
/// so a lost press or release is repaired by the next beat instead of leaving
/// the two ends disagreeing forever.
///
/// Anything the remote learns to hold later belongs in `buttons`/`modifiers`;
/// nothing else about the mechanism has to change.
public struct HeartbeatPayload: Codable, Equatable, Sendable {
    public let isActive: Bool
    public let buttons: UInt8
    public let modifiers: UInt8
    /// How often the sender intends to beat.  The receiver's patience is a
    /// multiple of this, so a single dropped message is never enough to
    /// release anything.
    public let heartbeatIntervalMs: UInt16

    public init(
        isActive: Bool,
        buttons: UInt8 = 0,
        modifiers: UInt8 = 0,
        heartbeatIntervalMs: UInt16 = 250
    ) {
        self.isActive = isActive
        self.buttons = buttons
        self.modifiers = modifiers
        self.heartbeatIntervalMs = heartbeatIntervalMs
    }

    public init(
        isActive: Bool,
        buttons: HeldButtons,
        modifiers: HeldModifiers,
        heartbeatIntervalMs: UInt16 = 250
    ) {
        self.init(
            isActive: isActive,
            buttons: buttons.rawValue,
            modifiers: modifiers.rawValue,
            heartbeatIntervalMs: heartbeatIntervalMs
        )
    }

    public var heldButtons: HeldButtons { HeldButtons(rawValue: buttons) }
    public var heldModifiers: HeldModifiers { HeldModifiers(rawValue: modifiers) }
}

/// Relative cursor movement in logical Mac points.
public struct PointerDeltaPayload: Codable, Equatable, Sendable {
    public let deltaX: Int16
    public let deltaY: Int16

    public init(deltaX: Int16, deltaY: Int16) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

/// Relative scroll movement in logical scroll units.
public struct ScrollDeltaPayload: Codable, Equatable, Sendable {
    public let deltaX: Int16
    public let deltaY: Int16

    public init(deltaX: Int16, deltaY: Int16) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public enum MouseButton: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case left = 1
    case right = 2
}

/// A single explicit mouse-button transition. It is reliable and idempotent
/// at the input-injection boundary.
public struct MouseButtonPayload: Codable, Equatable, Sendable {
    public static let maximumClickCount: UInt8 = 3

    public let button: MouseButton
    public let isDown: Bool
    /// Which click of a run this press continues. Two makes a Mac widen a text
    /// selection by word rather than starting a new one, and three by line.
    /// A message without the field means one, so a build that predates it
    /// still decodes.
    public let clickCount: UInt8

    public init(button: MouseButton, isDown: Bool, clickCount: UInt8 = 1) {
        self.button = button
        self.isDown = isDown
        self.clickCount = min(max(clickCount, 1), Self.maximumClickCount)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            button: try container.decode(MouseButton.self, forKey: .button),
            isDown: try container.decode(Bool.self, forKey: .isDown),
            clickCount: try container.decodeIfPresent(UInt8.self, forKey: .clickCount) ?? 1
        )
    }
}

/// A double click is one atomic message rather than two click pairs, because
/// two pairs crossing the link separately can arrive too far apart for the Mac
/// to read them as one double click.
public struct MouseDoubleClickPayload: Codable, Equatable, Sendable {
    public let button: MouseButton

    public init(button: MouseButton) {
        self.button = button
    }
}

/// Ordinary text is encoded as UTF-8 bytes so the protocol remains explicit
/// about byte limits and does not depend on a platform string ABI.
public struct TextInputPayload: Codable, Equatable, Sendable {
    public let utf8: ProtocolBytes

    public init(utf8: [UInt8]) throws {
        self.utf8 = try ProtocolBytes(bytes: utf8)
    }

    public init(text: String) throws {
        try self.init(utf8: Array(text.utf8))
    }

    public var text: String? {
        String(bytes: utf8.bytes, encoding: .utf8)
    }
}

/// The intentionally small hotkey allowlist. These values are atomic actions,
/// not a general key-script language.
public enum HotkeyAction: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case copy = 1
    case paste = 2
    case undo = 3
    case redo = 4
    case selectAll = 5
    case escape = 6
    case returnKey = 7
    case tab = 8
    case arrowUp = 9
    case arrowDown = 10
    case arrowLeft = 11
    case arrowRight = 12
    // 13 was Command+Tab, replaced by the appSwitcher message, which has to
    // hold Command open across several messages. The value is retired.
    case deleteBackward = 14
    case shiftTab = 15
    case deleteWordBackward = 16
    case deleteLineBackward = 17
    case missionControl = 18
    case appExpose = 19
}

/// The app switcher is a held gesture, not a chord: Command stays down from
/// `begin` until `commit`, so the phone can step through the row first. The
/// Mac tracks that held Command in its safety layer and releases it on
/// disconnect, lock, or sleep.
public enum AppSwitcherPhase: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case begin = 1
    case next = 2
    case previous = 3
    case commit = 4
    case cancel = 5
}

public struct AppSwitcherPayload: Codable, Equatable, Sendable {
    public let phase: AppSwitcherPhase

    public init(phase: AppSwitcherPhase) {
        self.phase = phase
    }
}

public struct HotkeyPayload: Codable, Equatable, Sendable {
    public let action: HotkeyAction

    public init(action: HotkeyAction) {
        self.action = action
    }
}

/// Relative movement derived from fused device attitude/rotation. The motion
/// producer is outside this shared module; units are normalized pointer points.
public struct MotionPointerDeltaPayload: Codable, Equatable, Sendable {
    public let deltaX: Int16
    public let deltaY: Int16
    public let sampleRateHz: UInt16

    public init(deltaX: Int16, deltaY: Int16, sampleRateHz: UInt16) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.sampleRateHz = sampleRateHz
    }
}

public struct AudioChunkPayload: Equatable, Sendable {
    public let streamID: SessionID
    public let chunkIndex: UInt32
    public let sampleRateHz: UInt32
    public let channels: UInt8
    public let bitsPerSample: UInt8
    public let pcm: ProtocolBytes
    public let samplePosition: UInt64
    public let isLast: Bool

    public init(
        streamID: SessionID,
        chunkIndex: UInt32,
        sampleRateHz: UInt32 = 16_000,
        channels: UInt8 = 1,
        bitsPerSample: UInt8 = 16,
        pcm: [UInt8],
        samplePosition: UInt64 = 0,
        isLast: Bool = false
    ) throws {
        self.streamID = streamID
        self.chunkIndex = chunkIndex
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.pcm = try ProtocolBytes(bytes: pcm)
        self.samplePosition = samplePosition
        self.isLast = isLast
    }
}

extension AudioChunkPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case streamID
        case chunkIndex
        case sampleRateHz
        case channels
        case bitsPerSample
        case pcm
        case samplePosition
        case isLast
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(SessionID.self, forKey: .streamID)
        chunkIndex = try container.decode(UInt32.self, forKey: .chunkIndex)
        sampleRateHz = try container.decode(UInt32.self, forKey: .sampleRateHz)
        channels = try container.decode(UInt8.self, forKey: .channels)
        bitsPerSample = try container.decode(UInt8.self, forKey: .bitsPerSample)
        samplePosition = try container.decodeIfPresent(UInt64.self, forKey: .samplePosition) ?? 0
        isLast = try container.decodeIfPresent(Bool.self, forKey: .isLast) ?? false

        if let encoded = try? container.decode(String.self, forKey: .pcm) {
            guard let data = Data(base64Encoded: encoded) else {
                throw ProtocolError.invalidField("audio_pcm_base64")
            }
            pcm = try ProtocolBytes(bytes: Array(data))
        } else {
            pcm = try container.decode(ProtocolBytes.self, forKey: .pcm)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(chunkIndex, forKey: .chunkIndex)
        try container.encode(sampleRateHz, forKey: .sampleRateHz)
        try container.encode(channels, forKey: .channels)
        try container.encode(bitsPerSample, forKey: .bitsPerSample)
        try container.encode(Data(pcm.bytes).base64EncodedString(), forKey: .pcm)
        try container.encode(samplePosition, forKey: .samplePosition)
        try container.encode(isLast, forKey: .isLast)
    }
}

public enum AcknowledgementStatus: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case accepted = 1
    case duplicate = 2
    case rejected = 3
}

public struct AcknowledgementPayload: Codable, Equatable, Sendable {
    public let acknowledgedSequence: UInt64
    public let status: AcknowledgementStatus

    public init(acknowledgedSequence: UInt64, status: AcknowledgementStatus) {
        self.acknowledgedSequence = acknowledgedSequence
        self.status = status
    }
}

public enum ConnectionState: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case disconnected = 1
    case connecting = 2
    case connected = 3
    case authenticated = 4
    case paused = 5
}

public struct ConnectionStatusPayload: Codable, Equatable, Sendable {
    public let state: ConnectionState
    public let reasonCode: UInt16

    public init(state: ConnectionState, reasonCode: UInt16 = 0) {
        self.state = state
        self.reasonCode = reasonCode
    }
}

public enum ProtocolErrorCode: UInt16, Codable, CaseIterable, Equatable, Sendable {
    case malformedMessage = 1
    case unsupportedVersion = 2
    case unauthenticated = 3
    case expiredPairing = 4
    case permissionDenied = 5
    case unsafeState = 6
    case unsupportedMessage = 7
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public let code: ProtocolErrorCode
    public let retryable: Bool

    public init(code: ProtocolErrorCode, retryable: Bool) {
        self.code = code
        self.retryable = retryable
    }
}

public struct PingPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct PongPayload: Codable, Equatable, Sendable {
    public init() {}
}

/// Typed payload union. The nested `type` field is deliberately redundant
/// with the envelope `messageType`; the decoder checks that they agree.
public enum MessagePayload: Codable, Equatable, Sendable {
    case heartbeat(HeartbeatPayload)
    case pointerDelta(PointerDeltaPayload)
    case scrollDelta(ScrollDeltaPayload)
    case mouseButton(MouseButtonPayload)
    case mouseDoubleClick(MouseDoubleClickPayload)
    case textInput(TextInputPayload)
    case hotkey(HotkeyPayload)
    case appSwitcher(AppSwitcherPayload)
    case motionPointerDelta(MotionPointerDeltaPayload)
    case audioChunk(AudioChunkPayload)
    case acknowledgement(AcknowledgementPayload)
    case connectionStatus(ConnectionStatusPayload)
    case error(ErrorPayload)
    case ping(PingPayload)
    case pong(PongPayload)

    public var messageType: MessageType {
        switch self {
        case .heartbeat: return .heartbeat
        case .pointerDelta: return .pointerDelta
        case .scrollDelta: return .scrollDelta
        case .mouseButton: return .mouseButton
        case .mouseDoubleClick: return .mouseDoubleClick
        case .textInput: return .textInput
        case .hotkey: return .hotkey
        case .appSwitcher: return .appSwitcher
        case .motionPointerDelta: return .motionPointerDelta
        case .audioChunk: return .audioChunk
        case .acknowledgement: return .acknowledgement
        case .connectionStatus: return .connectionStatus
        case .error: return .error
        case .ping: return .ping
        case .pong: return .pong
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(UInt8.self, forKey: .type)
        guard let type = MessageType(rawValue: rawType) else {
            throw ProtocolError.unknownMessageType(rawType)
        }

        switch type {
        case .heartbeat:
            self = .heartbeat(try container.decode(HeartbeatPayload.self, forKey: .value))
        case .pointerDelta:
            self = .pointerDelta(try container.decode(PointerDeltaPayload.self, forKey: .value))
        case .scrollDelta:
            self = .scrollDelta(try container.decode(ScrollDeltaPayload.self, forKey: .value))
        case .mouseButton:
            self = .mouseButton(try container.decode(MouseButtonPayload.self, forKey: .value))
        case .mouseDoubleClick:
            self = .mouseDoubleClick(try container.decode(MouseDoubleClickPayload.self, forKey: .value))
        case .textInput:
            self = .textInput(try container.decode(TextInputPayload.self, forKey: .value))
        case .hotkey:
            self = .hotkey(try container.decode(HotkeyPayload.self, forKey: .value))
        case .appSwitcher:
            self = .appSwitcher(try container.decode(AppSwitcherPayload.self, forKey: .value))
        case .motionPointerDelta:
            self = .motionPointerDelta(try container.decode(MotionPointerDeltaPayload.self, forKey: .value))
        case .audioChunk:
            self = .audioChunk(try container.decode(AudioChunkPayload.self, forKey: .value))
        case .acknowledgement:
            self = .acknowledgement(try container.decode(AcknowledgementPayload.self, forKey: .value))
        case .connectionStatus:
            self = .connectionStatus(try container.decode(ConnectionStatusPayload.self, forKey: .value))
        case .error:
            self = .error(try container.decode(ErrorPayload.self, forKey: .value))
        case .ping:
            self = .ping(try container.decode(PingPayload.self, forKey: .value))
        case .pong:
            self = .pong(try container.decode(PongPayload.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageType.rawValue, forKey: .type)

        switch self {
        case .heartbeat(let value): try container.encode(value, forKey: .value)
        case .pointerDelta(let value): try container.encode(value, forKey: .value)
        case .scrollDelta(let value): try container.encode(value, forKey: .value)
        case .mouseButton(let value): try container.encode(value, forKey: .value)
        case .mouseDoubleClick(let value): try container.encode(value, forKey: .value)
        case .textInput(let value): try container.encode(value, forKey: .value)
        case .hotkey(let value): try container.encode(value, forKey: .value)
        case .appSwitcher(let value): try container.encode(value, forKey: .value)
        case .motionPointerDelta(let value): try container.encode(value, forKey: .value)
        case .audioChunk(let value): try container.encode(value, forKey: .value)
        case .acknowledgement(let value): try container.encode(value, forKey: .value)
        case .connectionStatus(let value): try container.encode(value, forKey: .value)
        case .error(let value): try container.encode(value, forKey: .value)
        case .ping(let value): try container.encode(value, forKey: .value)
        case .pong(let value): try container.encode(value, forKey: .value)
        }
    }

    public func validate() throws {
        switch self {
        case .heartbeat(let value):
            guard value.buttons & ~HeldButtons.all.rawValue == 0 else {
                throw ProtocolError.invalidField("heartbeat_buttons")
            }
            guard value.modifiers & ~HeldModifiers.all.rawValue == 0 else {
                throw ProtocolError.invalidField("heartbeat_modifiers")
            }
            guard (100...1_000).contains(Int(value.heartbeatIntervalMs)) else {
                throw ProtocolError.outOfRange("heartbeat_interval_ms")
            }
        case .pointerDelta(let value):
            try validateDelta(x: value.deltaX, y: value.deltaY, field: "pointer_delta")
        case .scrollDelta(let value):
            try validateDelta(x: value.deltaX, y: value.deltaY, field: "scroll_delta")
        case .mouseButton, .mouseDoubleClick:
            break
        case .textInput(let value):
            guard !value.utf8.bytes.isEmpty else {
                throw ProtocolError.invalidField("text_empty")
            }
            guard value.text != nil else {
                throw ProtocolError.invalidUTF8
            }
        case .hotkey, .appSwitcher:
            break
        case .motionPointerDelta(let value):
            try validateDelta(x: value.deltaX, y: value.deltaY, field: "motion_pointer_delta")
            guard (1...100).contains(Int(value.sampleRateHz)) else {
                throw ProtocolError.outOfRange("motion_sample_rate_hz")
            }
        case .audioChunk(let value):
            guard value.streamID.bytes.count == SessionID.byteCount else {
                throw ProtocolError.invalidField("audio_stream_id_length")
            }
            guard value.sampleRateHz == 16_000, value.channels == 1, value.bitsPerSample == 16 else {
                throw ProtocolError.invalidField("audio_format")
            }
            guard !value.pcm.bytes.isEmpty else {
                throw ProtocolError.invalidField("audio_empty")
            }
            guard value.pcm.bytes.count.isMultiple(of: 2) else {
                throw ProtocolError.invalidField("audio_pcm_alignment")
            }
        case .acknowledgement(let value):
            guard value.acknowledgedSequence > 0 else {
                throw ProtocolError.invalidField("ack_sequence")
            }
        case .connectionStatus:
            break
        case .error:
            break
        case .ping, .pong:
            break
        }
    }

    private func validateDelta<T: FixedWidthInteger>(x: T, y: T, field: String) throws {
        let maximum = 8_192
        guard abs(Int64(x)) <= maximum, abs(Int64(y)) <= maximum else {
            throw ProtocolError.outOfRange(field)
        }
    }
}

/// The v1 envelope. The payload is the authenticated plaintext boundary; the
/// future AEAD layer authenticates the header fields and this typed payload.
public struct ProtocolEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: UInt8
    public let sessionID: SessionID
    public let sequence: UInt64
    public let timestampMs: Int64
    public let messageType: MessageType
    public let payload: MessagePayload

    public init(
        protocolVersion: UInt8 = ProtocolVersion.v1.rawValue,
        sessionID: SessionID,
        sequence: UInt64,
        timestampMs: Int64,
        payload: MessagePayload
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.messageType = payload.messageType
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case sessionID
        case sequence
        case timestampMs
        case messageType
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt8.self, forKey: .protocolVersion)
        guard version == ProtocolVersion.v1.rawValue else {
            throw ProtocolError.unsupportedVersion(version)
        }

        let sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        let sequence = try container.decode(UInt64.self, forKey: .sequence)
        let timestampMs = try container.decode(Int64.self, forKey: .timestampMs)
        let rawMessageType = try container.decode(UInt8.self, forKey: .messageType)
        guard let messageType = MessageType(rawValue: rawMessageType) else {
            throw ProtocolError.unknownMessageType(rawMessageType)
        }
        let payload = try container.decode(MessagePayload.self, forKey: .payload)

        guard payload.messageType == messageType else {
            throw ProtocolError.payloadTypeMismatch(expected: messageType, actual: payload.messageType)
        }

        self.protocolVersion = version
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.messageType = messageType
        self.payload = payload
    }

    public func validate() throws {
        guard protocolVersion == ProtocolVersion.v1.rawValue else {
            throw ProtocolError.unsupportedVersion(protocolVersion)
        }
        guard sequence > 0 else {
            throw ProtocolError.invalidField("sequence")
        }
        guard timestampMs >= 0 else {
            throw ProtocolError.invalidField("timestamp_ms")
        }
        guard messageType == payload.messageType else {
            throw ProtocolError.payloadTypeMismatch(expected: messageType, actual: payload.messageType)
        }
        try payload.validate()
    }
}

/// Deterministic classification of a received sequence number.
public enum SequenceDisposition: Equatable, Sendable {
    case firstAccepted
    case accepted
    case gap(expected: UInt64, received: UInt64)
    case duplicate
    case outOfOrder
    case invalid
}

/// Tracks sequence numbers independently from transport framing. A gap is
/// surfaced and the new sequence is accepted so unreliable streams continue;
/// reliable consumers can use the disposition to request a retry.
public struct SequenceTracker: Equatable, Sendable {
    public private(set) var lastAccepted: UInt64?

    public init(lastAccepted: UInt64? = nil) {
        self.lastAccepted = lastAccepted
    }

    @discardableResult
    public mutating func observe(sequence: UInt64) -> SequenceDisposition {
        guard sequence > 0 else { return .invalid }

        guard let lastAccepted else {
            self.lastAccepted = sequence
            return sequence == 1 ? .firstAccepted : .gap(expected: 1, received: sequence)
        }

        if sequence == lastAccepted {
            return .duplicate
        }
        if sequence < lastAccepted {
            return .outOfOrder
        }
        if sequence == lastAccepted + 1 {
            self.lastAccepted = sequence
            return .accepted
        }

        self.lastAccepted = sequence
        return .gap(expected: lastAccepted + 1, received: sequence)
    }
}

/// Decoder/encoder failures are intentionally coarse around untrusted input;
/// they never include payload bytes, text, keys, or QR material in messages.
public enum ProtocolError: Error, Equatable, Sendable {
    case emptyInput
    case envelopeTooLarge(actual: Int, limit: Int)
    case malformedInput
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case invalidSessionID
    case invalidField(String)
    case fieldTooLarge(String, actual: Int, limit: Int)
    case outOfRange(String)
    case invalidUTF8
    case payloadTypeMismatch(expected: MessageType, actual: MessageType)
}
