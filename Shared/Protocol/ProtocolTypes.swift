// Copyright © 2026 NewMotion contributors.
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
    // 8 was audioChunk, when the Mac transcribed and the phone shipped it the
    // sound. The phone transcribes now; 8 must not be reused for anything else.
    case acknowledgement = 9
    case connectionStatus = 10
    case error = 11
    case ping = 12
    case pong = 13
    case mouseDoubleClick = 14
    case tabWalk = 15
    case deleteScrub = 16
    case vocabulary = 17
    case spokenText = 18
    case keyPicker = 19
    case transcriptPreview = 20

    public var deliveryClass: DeliveryClass {
        switch self {
        // A lost preview is repaired by the next one a tenth of a second
        // later, and re-sending stale words is worse than dropping them.
        case .heartbeat, .pointerDelta, .scrollDelta, .motionPointerDelta,
             .transcriptPreview:
            return .unreliable
        case .mouseButton, .mouseDoubleClick, .textInput, .hotkey, .tabWalk,
             .deleteScrub, .vocabulary, .spokenText, .keyPicker,
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
public enum HeldModifier: UInt8, Codable, CaseIterable, Equatable, Sendable {
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

/// Words the Mac has seen on its own screen, pushed to the phone so its
/// recogniser can lean towards them.  The Mac is the only side that can walk
/// the screen, and the phone is the only side that transcribes, so the list
/// has to cross.  Bounded on both ends: a busy window must not be able to
/// overrun the envelope, and a decoder must refuse an oversized array before
/// it reserves storage for it.
public struct VocabularyPayload: Codable, Equatable, Sendable {
    /// Matches `ScreenVocabulary.maximumPhrases` on the Mac.
    public static let maximumPhrases = 40
    public static let maximumPhraseUTF8Bytes = 64
    /// Leaves room inside the 8192-byte envelope for JSON string escaping.
    public static let maximumTotalUTF8Bytes = 2_048

    public let phrases: [String]

    public init(phrases: [String]) throws {
        try Self.check(count: phrases.count)
        try Self.check(phrases: phrases)
        self.phrases = phrases
    }

    /// Trims a candidate list to something this payload will accept.  A single
    /// long token on screen should cost that token, not the whole push.
    public static func bounded(_ phrases: [String]) -> [String] {
        var kept: [String] = []
        var total = 0
        for phrase in phrases where !phrase.isEmpty {
            let bytes = phrase.utf8.count
            guard bytes <= maximumPhraseUTF8Bytes else { continue }
            guard kept.count < maximumPhrases, total + bytes <= maximumTotalUTF8Bytes else { break }
            kept.append(phrase)
            total += bytes
        }
        return kept
    }

    private enum CodingKeys: String, CodingKey {
        case phrases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .phrases)
        if let declared = list.count {
            try Self.check(count: declared)
        }
        var result: [String] = []
        while !list.isAtEnd {
            try Self.check(count: result.count + 1)
            result.append(try list.decode(String.self))
        }
        try Self.check(phrases: result)
        phrases = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phrases, forKey: .phrases)
    }

    private static func check(count: Int) throws {
        guard count <= maximumPhrases else {
            throw ProtocolError.fieldTooLarge("vocabulary_phrases", actual: count, limit: maximumPhrases)
        }
    }

    private static func check(phrases: [String]) throws {
        var total = 0
        for phrase in phrases {
            let bytes = phrase.utf8.count
            guard bytes > 0 else { throw ProtocolError.invalidField("vocabulary_phrase_empty") }
            guard bytes <= maximumPhraseUTF8Bytes else {
                throw ProtocolError.fieldTooLarge(
                    "vocabulary_phrase", actual: bytes, limit: maximumPhraseUTF8Bytes
                )
            }
            total += bytes
        }
        guard total <= maximumTotalUTF8Bytes else {
            throw ProtocolError.fieldTooLarge(
                "vocabulary_total", actual: total, limit: maximumTotalUTF8Bytes
            )
        }
    }
}

/// A finished utterance, transcribed on the phone.  Kept apart from
/// `textInput` so the Mac can tell spoken words from typed ones: only spoken
/// words feed the vocabulary cache, and only they take the secure-input check
/// that guards dictation.
public struct SpokenTextPayload: Codable, Equatable, Sendable {
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
    // 13 was Command+Tab, replaced by the tabWalk message, which has to hold
    // Command open across several messages. The value is retired.
    case deleteBackward = 14
    case shiftTab = 15
    case deleteWordBackward = 16
    case deleteLineBackward = 17
    case missionControl = 18
    case appExpose = 19
    // 20 was Control+Tab, replaced by the tabWalk message, which has to hold
    // Control open across several messages. The value is retired.
    case nextWindow = 21
    case newItem = 22
    case newTab = 23
    case closeWindow = 24
    case selectLeft = 25
    case selectRight = 26
    case selectUp = 27
    case selectDown = 28
    case controlCenter = 29
    case cut = 30
    case save = 31
    case find = 32
    case previousWindow = 33
}

/// A held press on the phone's Command key, aimed across the picker grid.
/// Unlike the tab walk, the Mac holds nothing down while it lasts: the chord
/// is one atomic hotkey fired at `commit`, so a press that never ends can
/// leave nothing stuck.
public enum KeyPickerPhase: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case begin = 1
    case highlight = 2
    case commit = 3
    case cancel = 4
}

public struct KeyPickerPayload: Codable, Equatable, Sendable {
    public let phase: KeyPickerPhase
    /// `begin` and `cancel` name no cell. `highlight` names the newly lit one.
    /// `commit` names the cell to fire, or none if the finger never moved.
    /// Commit carrying its own cell is what makes a dropped highlight cost a
    /// stale card rather than the wrong shortcut.
    public let cell: HotkeyAction?

    public init(phase: KeyPickerPhase, cell: HotkeyAction? = nil) {
        self.phase = phase
        self.cell = cell
    }
}

/// The picker's keyboard: the cells, in the order they are drawn.
///
/// Both apps read this table and neither may reorder it alone. The wire says
/// which cell is lit, never where a finger is, so a phone and a Mac drawing
/// different grids would still agree on every message and quietly light and
/// fire different things.
public enum KeyPickerGrid {
    public static let rows: [[HotkeyAction]] = [
        [.cut, .copy, .paste, .undo, .redo],
        [.newItem, .newTab, .save, .closeWindow, .find],
        [.selectAll, .deleteLineBackward, .nextWindow, .previousWindow]
    ]

    /// Every cell in `rows` has one. Nothing outside the grid does, because no
    /// other hotkey is ever drawn.
    public static func displayName(for cell: HotkeyAction) -> String? {
        displayNames[cell]
    }

    private static let displayNames: [HotkeyAction: String] = [
        .cut: "Cut",
        .copy: "Copy",
        .paste: "Paste",
        .undo: "Undo",
        .redo: "Redo",
        .newItem: "New",
        .newTab: "New Tab",
        .save: "Save",
        .closeWindow: "Close",
        .find: "Find",
        .selectAll: "Select All",
        .deleteLineBackward: "Delete Line",
        .nextWindow: "Next Window",
        .previousWindow: "Prev Window"
    ]
}

/// The words the phone's recogniser has heard so far, on their way to the Mac
/// card. Each message carries the whole current preview rather than a change
/// to it, so a dropped one is repaired by the next instead of leaving the two
/// ends disagreeing. An empty payload means "clear", and is valid.
public struct TranscriptPreviewPayload: Codable, Equatable, Sendable {
    /// A glance at the tail of a sentence, not a transcript, so far below
    /// `ProtocolBytes.maximumCount`: ten of these a second share the link with
    /// the typing they are previewing.
    public static let maximumUTF8Bytes = 256

    public let utf8: ProtocolBytes

    public init(utf8: [UInt8]) throws {
        guard utf8.count <= Self.maximumUTF8Bytes else {
            throw ProtocolError.fieldTooLarge(
                "transcript_preview", actual: utf8.count, limit: Self.maximumUTF8Bytes
            )
        }
        self.utf8 = try ProtocolBytes(bytes: utf8)
    }

    public init(text: String) throws {
        try self.init(utf8: Array(text.utf8))
    }

    public var text: String? {
        String(bytes: utf8.bytes, encoding: .utf8)
    }
}

/// Holding a modifier and walking with Tab: Command for the app switcher,
/// Control for the tab bar of whatever is in front. It is a held gesture, not
/// a chord, because the modifier stays down from `begin` until `commit` so the
/// phone can step along the row first. The Mac tracks that held modifier in
/// its safety layer and releases it on disconnect, lock, or sleep.
public enum TabWalkPhase: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case begin = 1
    case next = 2
    case previous = 3
    case commit = 4
    case cancel = 5
}

public struct TabWalkPayload: Codable, Equatable, Sendable {
    public let phase: TabWalkPhase
    /// The modifier held open for the whole walk. Which one it is decides what
    /// the walk steps through; nothing else about the gesture changes.
    public let modifier: HeldModifier

    public init(phase: TabWalkPhase, modifier: HeldModifier) {
        self.phase = phase
        self.modifier = modifier
    }
}

/// A delete key that is being held and slid sideways, one notch at a time.
/// The phone counts the notches; it cannot know what is in the field, so it
/// never says how much text a notch stands for.
public enum DeleteScrubPhase: UInt8, Codable, CaseIterable, Equatable, Sendable {
    /// The key went down. Nothing is deleted yet; it only gives the Mac a head
    /// start on waking the focused field.
    case begin = 1
    case delete = 2
    case restore = 3
    /// The key came up, so what this press deleted can no longer be restored.
    case end = 4
}

/// What one notch stands for. The two delete keys differ in nothing else.
public enum DeleteScrubGranularity: UInt8, Codable, CaseIterable, Equatable, Sendable {
    case character = 1
    case word = 2
}

public struct DeleteScrubPayload: Codable, Equatable, Sendable {
    public let phase: DeleteScrubPhase
    public let granularity: DeleteScrubGranularity

    public init(phase: DeleteScrubPhase, granularity: DeleteScrubGranularity) {
        self.phase = phase
        self.granularity = granularity
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
    case tabWalk(TabWalkPayload)
    case deleteScrub(DeleteScrubPayload)
    case vocabulary(VocabularyPayload)
    case spokenText(SpokenTextPayload)
    case keyPicker(KeyPickerPayload)
    case transcriptPreview(TranscriptPreviewPayload)
    case motionPointerDelta(MotionPointerDeltaPayload)
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
        case .tabWalk: return .tabWalk
        case .deleteScrub: return .deleteScrub
        case .vocabulary: return .vocabulary
        case .spokenText: return .spokenText
        case .keyPicker: return .keyPicker
        case .transcriptPreview: return .transcriptPreview
        case .motionPointerDelta: return .motionPointerDelta
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
        case .tabWalk:
            self = .tabWalk(try container.decode(TabWalkPayload.self, forKey: .value))
        case .deleteScrub:
            self = .deleteScrub(try container.decode(DeleteScrubPayload.self, forKey: .value))
        case .vocabulary:
            self = .vocabulary(try container.decode(VocabularyPayload.self, forKey: .value))
        case .spokenText:
            self = .spokenText(try container.decode(SpokenTextPayload.self, forKey: .value))
        case .keyPicker:
            self = .keyPicker(try container.decode(KeyPickerPayload.self, forKey: .value))
        case .transcriptPreview:
            self = .transcriptPreview(try container.decode(TranscriptPreviewPayload.self, forKey: .value))
        case .motionPointerDelta:
            self = .motionPointerDelta(try container.decode(MotionPointerDeltaPayload.self, forKey: .value))
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
        case .tabWalk(let value): try container.encode(value, forKey: .value)
        case .deleteScrub(let value): try container.encode(value, forKey: .value)
        case .vocabulary(let value): try container.encode(value, forKey: .value)
        case .spokenText(let value): try container.encode(value, forKey: .value)
        case .keyPicker(let value): try container.encode(value, forKey: .value)
        case .transcriptPreview(let value): try container.encode(value, forKey: .value)
        case .motionPointerDelta(let value): try container.encode(value, forKey: .value)
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
        // A cell riding along on `begin` or `cancel` is ignored rather than
        // refused: only what `commit` names is ever fired.
        case .hotkey, .tabWalk, .deleteScrub, .vocabulary, .keyPicker:
            break
        case .spokenText(let value):
            guard !value.utf8.bytes.isEmpty else {
                throw ProtocolError.invalidField("spoken_text_empty")
            }
            guard value.text != nil else {
                throw ProtocolError.invalidUTF8
            }
        case .transcriptPreview(let value):
            // No empty check, unlike spoken text: an empty preview is the
            // message that clears the card, and refusing it would break every
            // clear.
            guard value.utf8.bytes.count <= TranscriptPreviewPayload.maximumUTF8Bytes else {
                throw ProtocolError.fieldTooLarge(
                    "transcript_preview",
                    actual: value.utf8.bytes.count,
                    limit: TranscriptPreviewPayload.maximumUTF8Bytes
                )
            }
            guard value.text != nil else {
                throw ProtocolError.invalidUTF8
            }
        case .motionPointerDelta(let value):
            try validateDelta(x: value.deltaX, y: value.deltaY, field: "motion_pointer_delta")
            guard (1...100).contains(Int(value.sampleRateHz)) else {
                throw ProtocolError.outOfRange("motion_sample_rate_hz")
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
    case invalidField(String)
    case fieldTooLarge(String, actual: Int, limit: Int)
    case outOfRange(String)
    case invalidUTF8
    case payloadTypeMismatch(expected: MessageType, actual: MessageType)
}
