import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// Decides which of the recogniser's rough partials are worth a message.
///
/// Apple's analyser revises a partial many times a second, and every one of
/// them shares the link with the typing it is previewing, so this drops the
/// revisions that changed nothing and holds the rest to ten a second.  The
/// clock is passed in rather than read, so its tests do not sleep.
public struct TranscriptPreviewThrottle: Sendable {
    /// What a revision is worth.
    public enum Decision: Equatable, Sendable {
        /// These words, cut to the wire's cap, are worth a message now.
        case send(String)
        /// Nothing the card is not already showing.
        case nothing
        /// New words, but too soon after the last send.  They are owed a
        /// message in this many seconds; without one the card waits for the
        /// keepalive, or never sees them at all if the utterance ends first.
        case tooSoon(after: Double)
    }

    /// Ten a second: fast enough to read as live, slow enough that the
    /// finished sentence behind it is not queued up behind previews.
    public static let minimumInterval: Double = 0.1

    /// How long the same words may sit unsent.  The Mac wipes its card after
    /// two silent seconds, which is the guarantee against a lost clear on an
    /// unreliable channel.  The timer that repeats the words runs at this
    /// interval too, so the gap between two sends can reach twice it, and a
    /// message can still be lost on the way: half a second keeps the worst
    /// gap at one second, and a lost repeat inside the Mac's two.
    public static let keepaliveInterval: Double = 0.5

    /// Previews this utterance has put on the wire.
    public private(set) var sentCount = 0
    /// Characters in the last preview sent.  The only number a debug line may
    /// carry about a preview; the words themselves never leave this type.
    public var characterCount: Int { lastSent.count }

    private let minimumInterval: Double
    private let keepaliveInterval: Double
    private let maximumUTF8Bytes: Int
    private var lastSent = ""
    private var lastSentAt: Double?

    public init(
        minimumInterval: Double = TranscriptPreviewThrottle.minimumInterval,
        keepaliveInterval: Double = TranscriptPreviewThrottle.keepaliveInterval,
        maximumUTF8Bytes: Int = TranscriptPreviewPayload.maximumUTF8Bytes
    ) {
        self.minimumInterval = minimumInterval
        self.keepaliveInterval = keepaliveInterval
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }

    /// What to do with this partial.  Deciding is separate from recording so
    /// that a message the link refuses is offered again instead of being
    /// mistaken for words the card is already showing.
    public mutating func partial(_ text: String, at now: Double) -> Decision {
        // The clock first: trimming and the tail walk both run the length of
        // the whole utterance, and this is called on the main actor for every
        // revision the analyser makes, most of which are held back anyway.
        let sinceLastSend = lastSentAt.map { now - $0 }
        if let sinceLastSend, sinceLastSend < minimumInterval {
            return .tooSoon(after: minimumInterval - sinceLastSend)
        }
        let tail = Self.tail(
            of: text.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        if tail == lastSent, let sinceLastSend {
            // Words the card is already showing, so this is only worth the
            // wire once the Mac's idle clear is close.  An empty preview
            // counts: while the talk button is held it is the card saying it
            // is listening, and it has to be kept alive like any other.
            guard sinceLastSend >= keepaliveInterval else { return .nothing }
        }
        return .send(tail)
    }

    /// Records the words that reached the wire.  Only a send the link took
    /// counts: one it refused left the card unchanged, so the interval and the
    /// repeat check must both still let those words through.
    public mutating func sent(_ text: String, at now: Double) {
        lastSent = text
        lastSentAt = now
        sentCount += 1
    }

    /// Whether the Mac has a card up at all, and so needs the message that
    /// takes it down.  A card with no words on it still counts.  The utterance
    /// is over either way, so the throttle starts again from nothing.
    public mutating func clear() -> Bool {
        let hadPreview = lastSentAt != nil
        self = TranscriptPreviewThrottle(
            minimumInterval: minimumInterval,
            keepaliveInterval: keepaliveInterval,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        return hadPreview
    }

    /// The last words that fit the wire's cap, cut on a space so the card
    /// never opens mid-word.  A single word longer than the cap is cut hard,
    /// because otherwise it could not be shown at all.
    static func tail(of text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var kept: [Character] = []
        var bytes = 0
        // How many of `kept` reach back to the earliest whole word found so
        // far, the space itself left out.
        var wholeWords: Int?
        for character in text.reversed() {
            let size = String(character).utf8.count
            guard bytes + size <= maximumUTF8Bytes else { break }
            if character.isWhitespace, !kept.isEmpty { wholeWords = kept.count }
            kept.append(character)
            bytes += size
        }
        return String(kept.prefix(wholeWords ?? kept.count).reversed())
    }
}
#endif
