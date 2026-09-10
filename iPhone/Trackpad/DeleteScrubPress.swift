import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// One held press of a delete key: how far the finger has travelled, which
/// unit the key is set to, and what the two of those owe the Mac.
///
/// Kept apart from the key view the way the Command picker's press is, so a
/// whole press can be tested without a touch.
public struct DeleteScrubPress: Equatable, Sendable {
    /// One thing a press has to say.  A scrub message is for the Mac's delete
    /// coordinator and its card; a key is the plain backspace a tap ends with.
    public enum Message: Equatable, Sendable {
        case scrub(DeleteScrubPhase, DeleteScrubGranularity)
        case key(RemoteHotkey)
    }

    /// True once the key has gone down, which is what a lift has to close.
    public private(set) var hasBegun = false
    private var tracker = DeleteScrubTracker()
    /// Rest takes a character off; one slide up takes a whole word.
    private var dial = SlideDial(range: 0...1)
    /// A press that changed the unit was about the unit, not about deleting,
    /// so it must not also rub a character out when the finger lifts.
    private var hasChangedUnit = false

    public init() {}

    /// Notches this press is currently asking for.
    public var steps: Int { tracker.steps }
    /// True once the finger has travelled sideways at all, whether or not the
    /// count came back to where it started.
    public var hasStepped: Bool { tracker.hasStepped }
    public var isWord: Bool { dial.position == 1 }
    public var granularity: DeleteScrubGranularity { isWord ? .word : .character }
    /// The plain key a tap on this press would send.
    public var hotkey: RemoteHotkey { isWord ? .deleteWordBackward : .deleteBackward }

    /// Touch-down.  The press announces itself before anything has been asked
    /// for, because that is when the Mac starts waking the focused field and a
    /// Chromium field takes seconds to wake.
    public mutating func begin() -> [Message] {
        guard !hasBegun else { return [] }
        self = DeleteScrubPress()
        hasBegun = true
        return [.scrub(.begin, granularity)]
    }

    /// What this travel asks for.  The unit is settled before the notches are
    /// counted, so a slide that goes up and across erases what the key now says
    /// it will.
    public mutating func move(translationX: Double, translationY: Double) -> [Message] {
        guard hasBegun else { return [] }
        var messages: [Message] = []
        if dial.advance(translationY: translationY) {
            hasChangedUnit = true
            // A flip on its own erases nothing, so without this the Mac would
            // never hear that the key has changed what a notch takes off, and
            // its card would stay lit on the unit the press started in.
            messages.append(.scrub(.unitChanged, granularity))
        }
        for step in tracker.advance(translationX: translationX) {
            messages.append(.scrub(step.phase, granularity))
        }
        return messages
    }

    /// The lift.  The end always goes out, because it is where the Mac erases
    /// anything it had to hold back, so it arrives even for a tap that never
    /// slid.  Only a committed press that neither slid nor changed the unit
    /// also sends the plain key.
    public mutating func lift(committing: Bool) -> [Message] {
        guard hasBegun else { return [] }
        var messages: [Message] = [.scrub(.end, granularity)]
        if committing, !tracker.hasStepped, !hasChangedUnit {
            messages.append(.key(hotkey))
        }
        // The key reports back to characters as soon as the finger lifts, so
        // the label never shows a mode from a press that already ended.
        self = DeleteScrubPress()
        return messages
    }
}
#endif
