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
    public var link: String
    public var linkKind: String
    public var pairingProgress: String
    public var pairingProgressKind: String
    public var authenticated: Bool
    public var pairingOffer: String
    public var hasPairingQR: Bool
    public var pairingError: String?
    public var lastPairingFailure: String?
    public var lastProbe: String?
    public var peerName: String?
    public var lastApplicationMessage: String?
    /// Every notch of the last held delete key, oldest first.
    public var deleteScrub: String?
    /// Milliseconds the last paced key burst took to reach the window server.
    /// This is the Mac's own share of hotkey latency.
    public var keyPostMs: Double?
    /// Cursor and scroll deltas applied since launch.  Counting them keeps the
    /// 60 Hz stream off `lastApplicationMessage`, whose every assignment
    /// rebuilds this snapshot and re-renders the menu bar surface.
    public var cursorEvents: UInt64
    /// The last front-window vocabulary walk: "off", or "12ms/430nodes/18words"
    /// with "+" when the node budget ran out. Counts only, never the words.
    public var vocabulary: String
    /// One entry per pipeline stage, filled in as the response is written
    /// rather than as the snapshot is built: summarising sorts a window per
    /// stage, and the snapshot is rebuilt on the receive path.
    public var latency: [LatencySummary]
    public var appPath: String?
    public var pairedDevices: [MacDebugPairedDevice]

    public init(
        app: String = "PhoneRemoteMac",
        status: String,
        paused: Bool,
        accessibility: String,
        link: String,
        linkKind: String,
        pairingProgress: String,
        pairingProgressKind: String,
        authenticated: Bool,
        pairingOffer: String,
        hasPairingQR: Bool,
        pairingError: String? = nil,
        lastPairingFailure: String? = nil,
        lastProbe: String? = nil,
        peerName: String? = nil,
        lastApplicationMessage: String? = nil,
        deleteScrub: String? = nil,
        keyPostMs: Double? = nil,
        cursorEvents: UInt64 = 0,
        vocabulary: String = "off",
        latency: [LatencySummary] = [],
        appPath: String? = nil,
        pairedDevices: [MacDebugPairedDevice] = []
    ) {
        self.app = app
        self.status = status
        self.paused = paused
        self.accessibility = accessibility
        self.link = link
        self.linkKind = linkKind
        self.pairingProgress = pairingProgress
        self.pairingProgressKind = pairingProgressKind
        self.authenticated = authenticated
        self.pairingOffer = pairingOffer
        self.hasPairingQR = hasPairingQR
        self.pairingError = pairingError
        self.lastPairingFailure = lastPairingFailure
        self.lastProbe = lastProbe
        self.peerName = peerName
        self.lastApplicationMessage = lastApplicationMessage
        self.deleteScrub = deleteScrub
        self.keyPostMs = keyPostMs
        self.cursorEvents = cursorEvents
        self.vocabulary = vocabulary
        self.latency = latency
        self.appPath = appPath
        self.pairedDevices = pairedDevices
    }

    public static let empty = MacDebugSnapshot(
        status: "Remote: Disconnected",
        paused: false,
        accessibility: "unknown",
        link: "Unavailable",
        linkKind: "unavailable",
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
