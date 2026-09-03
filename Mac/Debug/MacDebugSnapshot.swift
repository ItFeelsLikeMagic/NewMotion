import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// Privacy-safe live state for local debugging. It never carries QR text,
/// keys, handshake bytes, or device identifiers.
public struct MacDebugPairedDevice: Equatable, Sendable, Codable {
    public var displayName: String
    public var pairedAt: Date

    public init(displayName: String, pairedAt: Date) {
        self.displayName = displayName
        self.pairedAt = pairedAt
    }
}

public struct MacDebugSnapshot: Equatable, Sendable, Codable {
    public var app: String
    public var status: String
    public var paused: Bool
    public var accessibility: String
    public var bluetooth: String
    public var bluetoothKind: String
    public var pairingProgress: String
    public var pairingProgressKind: String
    public var authenticated: Bool
    public var pairingOffer: String
    public var hasPairingQR: Bool
    public var pairingError: String?
    public var lastPairingFailure: String?
    public var lastProbe: String?
    public var visiblePeripheralName: String?
    public var lastApplicationMessage: String?
    /// Milliseconds the last paced key burst took to reach the window server.
    /// This is the Mac's own share of hotkey latency.
    public var keyPostMs: Double?
    /// Cursor and scroll deltas applied since launch.  Counting them keeps the
    /// 60 Hz stream off `lastApplicationMessage`, whose every assignment
    /// rebuilds this snapshot and re-renders the menu bar surface.
    public var cursorEvents: UInt64
    public var audioPhase: String
    public var audioFrames: UInt64
    public var audioSamples: UInt64
    public var audioMissingChunks: UInt64
    /// Which path the last spoken utterance took into the field.  A label, not
    /// text: the field's contents never reach this snapshot.
    public var audioMerge: String
    /// Stage times for the last spoken utterance, from the commit that ended
    /// the speech to the text landing: "asr 174/read 9/norm 380/type 6 = 569ms".
    public var audioTiming: String
    /// The last front-window vocabulary walk: "off", or "12ms/430nodes/18words"
    /// with "+" when the node budget ran out. Counts only, never the words.
    public var audioVocabulary: String
    public var appPath: String?
    public var pairedDevices: [MacDebugPairedDevice]

    public init(
        app: String = "PhoneRemoteMac",
        status: String,
        paused: Bool,
        accessibility: String,
        bluetooth: String,
        bluetoothKind: String,
        pairingProgress: String,
        pairingProgressKind: String,
        authenticated: Bool,
        pairingOffer: String,
        hasPairingQR: Bool,
        pairingError: String? = nil,
        lastPairingFailure: String? = nil,
        lastProbe: String? = nil,
        visiblePeripheralName: String? = nil,
        lastApplicationMessage: String? = nil,
        keyPostMs: Double? = nil,
        cursorEvents: UInt64 = 0,
        audioPhase: String = "idle",
        audioFrames: UInt64 = 0,
        audioSamples: UInt64 = 0,
        audioMissingChunks: UInt64 = 0,
        audioMerge: String = "none",
        audioTiming: String = "none",
        audioVocabulary: String = "off",
        appPath: String? = nil,
        pairedDevices: [MacDebugPairedDevice] = []
    ) {
        self.app = app
        self.status = status
        self.paused = paused
        self.accessibility = accessibility
        self.bluetooth = bluetooth
        self.bluetoothKind = bluetoothKind
        self.pairingProgress = pairingProgress
        self.pairingProgressKind = pairingProgressKind
        self.authenticated = authenticated
        self.pairingOffer = pairingOffer
        self.hasPairingQR = hasPairingQR
        self.pairingError = pairingError
        self.lastPairingFailure = lastPairingFailure
        self.lastProbe = lastProbe
        self.visiblePeripheralName = visiblePeripheralName
        self.lastApplicationMessage = lastApplicationMessage
        self.keyPostMs = keyPostMs
        self.cursorEvents = cursorEvents
        self.audioPhase = audioPhase
        self.audioFrames = audioFrames
        self.audioSamples = audioSamples
        self.audioMissingChunks = audioMissingChunks
        self.audioMerge = audioMerge
        self.audioTiming = audioTiming
        self.audioVocabulary = audioVocabulary
        self.appPath = appPath
        self.pairedDevices = pairedDevices
    }

    public static let empty = MacDebugSnapshot(
        status: "Remote: Disconnected",
        paused: false,
        accessibility: "unknown",
        bluetooth: "Idle",
        bluetoothKind: "idle",
        pairingProgress: "Ready to pair",
        pairingProgressKind: "idle",
        authenticated: false,
        pairingOffer: "idle",
        hasPairingQR: false
    )
}

public final class MacDebugSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MacDebugSnapshot

    public init(_ value: MacDebugSnapshot = .empty) {
        self.value = value
    }

    public func current() -> MacDebugSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ value: MacDebugSnapshot) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
