import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// One message on its way to the Mac.  Cursor travel rides the compact binary
/// frame; everything else rides the protocol envelope.
enum InputMessage {
    case payload(MessagePayload)
    case compact(body: Data, type: MessageType)
}

/// How badly a message needs to arrive.
enum InputDelivery {
    /// Cursor travel, where the newest value supersedes the last.  A refused
    /// message stays with the caller to resend; the link must never queue it,
    /// or the cursor replays a path the hand has already left.
    case latestWins
    /// A click, a key, a switcher phase.  It must arrive, and in order.
    case ordered
}

enum InputSendResult: Equatable {
    case sent
    /// No room right now.  A `latestWins` caller keeps its value and waits for
    /// `onReadyToSend`.
    case busy
    /// Nothing to send over.  Anything pending should be dropped.
    case unavailable
}

/// Everything the input pipeline needs from a link, and nothing more.  Input is
/// produced on the main actor and stays there down to the wire, so the whole
/// contract is main-actor isolated.  Sealing,
/// message numbering, fragmenting, and the wire's size limit all live below
/// this line, so putting the remote on Wi-Fi or USB replaces one object and
/// reaches no stage above it.
@MainActor
protocol InputLink: AnyObject {
    var isReady: Bool { get }
    /// Called when a link that answered `busy` has room again.
    var onReadyToSend: (() -> Void)? { get set }
    func send(_ message: InputMessage, delivery: InputDelivery) -> InputSendResult
}
