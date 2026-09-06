import Foundation

/// The only thing app logic needs from a connection: whole messages in, whole
/// messages out.  Everything a particular link must do to carry them - packet
/// sizes, fragmenting, reassembly, retries, radios, sockets, pairing to a
/// peer - lives below this line.  Adding Wi-Fi, a WebSocket, USB, or a second
/// phone platform means writing one conformer and changing no caller above it.
///
/// Sealing stays above the link, not inside it: the link is handed ciphertext
/// and never sees a key.
public protocol MessageLink: AnyObject {
    var state: RemoteLinkState { get }

    /// What to call the peer in the UI and in a trust record, when the link
    /// knows a name for it.
    var peerName: String? { get }

    /// The largest single message this link will accept.  Callers that build
    /// their own bodies size them against this; callers that send envelopes
    /// can ignore it, because the protocol cap is already smaller.
    var maximumMessageBytes: Int { get }

    var onStateChange: ((RemoteLinkState) -> Void)? { get set }

    /// One whole message, already reassembled.  Never a fragment.
    var onMessage: ((LinkChannel, Data) -> Void)? { get set }

    /// A link that answered `.busy` has room again.
    var onReadyToSend: (() -> Void)? { get set }

    var onError: ((LinkError) -> Void)? { get set }

    @discardableResult
    func send(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult

    /// Which peers this link should meet, each named by its beacon.  A link
    /// that announces itself, as the phone does, announces the first; a link
    /// that searches, as the Mac does, searches for all of them.  Empty means
    /// nobody: the link neither announces nor searches until told again.  May
    /// be called at any time; a link already announcing or searching changes
    /// over in place, and one already connected keeps its connection.
    func setBeacons(_ beacons: [UUID])

    /// Begin looking for the peer and keep the connection up. A link owns its
    /// own timers; nothing above it has to tick it.
    func start()
    func stop()
}

/// Which conversation a message belongs to. Two channels, because the
/// handshake has to flow before a session exists to protect anything, and it
/// must not be stuck behind a queue of cursor traffic. This is a protocol
/// split, not a Bluetooth one: every transport owes both.
public enum LinkChannel: UInt8, Equatable, Sendable, CaseIterable {
    /// The pairing handshake.
    case control = 0
    /// Everything after the handshake, sealed by the session.
    case data = 1
}

/// How far along the connection is. It stops at `connected`: whether the peer
/// is trusted is the app's question, not the link's, and a link that tracked
/// it would need to be told app state back.
public enum RemoteLinkState: Equatable, Sendable {
    /// No radio, no network, or no permission. Nothing to try yet.
    case unavailable
    /// Able to look, and looking.
    case searching
    /// Found the peer, setting the connection up.
    case connecting
    /// Messages can flow.
    case connected
}

/// What a sender wants from the link when there is no room right now. This is
/// deliberately not `DeliveryClass`: that says whether the receiver needs the
/// message guaranteed, which is a protocol question. This says whether waiting
/// a moment beats giving up, which is a link question, and the two do not line
/// up. Voice is unreliable on the wire and still worth queueing, because a
/// dropped chunk is a hole in what someone said.
public enum LinkDelivery: Equatable, Sendable {
    /// Guaranteed and in order. Queues, and the wire asks for acknowledgement.
    case reliable
    /// No guarantee, but worth waiting for room. Queues. Voice.
    case unreliableQueued
    /// No guarantee, and a stale one is worse than none, so it is never
    /// queued: the caller keeps the newest value and resends on
    /// `onReadyToSend`. Cursor travel, which must not replay a path the hand
    /// has already left.
    case latestWins

    /// What the wire's reliability bit should say for this message.
    public var isReliable: Bool { self == .reliable }

    /// Whether the link may hold the message until there is room.
    public var mayQueue: Bool { self != .latestWins }
}

public enum LinkSendResult: Equatable, Sendable {
    case sent
    /// No room right now. A caller holding the newest value of something keeps
    /// it and waits for `onReadyToSend`; a caller with an ordered message
    /// retries. The link never queues on the caller's behalf, because a queued
    /// cursor delta replays a path the hand has already left.
    case busy
    case notConnected
    /// Larger than `maximumMessageBytes`. Retrying will not help.
    case tooLarge
}

public enum LinkError: Error, Equatable, Sendable {
    /// The radio or network went away.
    case unavailable
    /// Looked for the peer and did not find it in time.
    case peerNotFound
    /// Found the peer but could not set the connection up.
    case setupFailed(String)
    /// The peer went away.
    case peerDisconnected
    /// Arrived, but not something this link could put back together.
    case malformedMessage
}
