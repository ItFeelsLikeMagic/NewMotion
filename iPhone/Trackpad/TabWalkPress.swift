import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// One held press of the walk key: which row it is walking, how far along that
/// row the finger has stepped, and what the two of those owe the Mac.
///
/// Kept apart from the key view the way the delete key's press is, so a whole
/// press can be tested without a touch.
public struct TabWalkPress: Equatable, Sendable {
    /// Travel per step.  Half a thumb's width: far enough that a wobble while
    /// holding does not step, close enough to cross a full switcher in one
    /// slide.
    public static let stepWidth: Double = 22

    /// True once the walk has been opened, which is what a lift has to close.
    public private(set) var hasBegun = false
    private var counter = SlideNotchCounter(stepWidth: TabWalkPress.stepWidth)
    /// Rest walks apps, one slide up walks the front app's tabs, one slide
    /// down walks its windows.
    private var dial = SlideDial(range: -1...1)

    public init() {}

    /// Every press starts on apps, so the key is the app switcher unless a
    /// thumb says otherwise, and it is the app switcher again by the next
    /// press.
    public var row: TabWalkRow {
        switch dial.position {
        case 1: return .tabs
        case -1: return .windows
        default: return .apps
        }
    }

    /// Touch-down.  Opening the walk also takes its first step, which is what
    /// makes a plain tap the ordinary one-step flip.
    public mutating func begin() -> [TabWalkPayload] {
        guard !hasBegun else { return [] }
        self = TabWalkPress()
        hasBegun = true
        return [TabWalkPayload(phase: .begin, row: row)]
    }

    /// What this travel asks for.  The row is settled before the steps are
    /// counted, so a slide that goes up and across walks the row the key has
    /// just changed to.
    public mutating func move(translationX: Double, translationY: Double) -> [TabWalkPayload] {
        guard hasBegun else { return [] }
        var messages: [TabWalkPayload] = []
        let leaving = row
        if dial.advance(translationY: translationY) {
            messages.append(TabWalkPayload(phase: .swap, row: row, leaving: leaving))
            // The travel spent reaching the swap belongs to the row that is
            // over, so the new one starts stepping from where the finger
            // stands rather than owing everything the old one walked.
            counter.reanchor(at: translationX)
        }
        let travelled = counter.advance(to: translationX)
        if travelled != 0 {
            let phase: TabWalkPhase = travelled > 0 ? .next : .previous
            messages.append(
                contentsOf: repeatElement(TabWalkPayload(phase: phase, row: row), count: abs(travelled))
            )
        }
        return messages
    }

    /// The lift.  A commit takes whatever the walk is standing on; a cancel
    /// escapes out of it.  Either way whatever the Mac is holding is released,
    /// which is the one thing this press must never fail to say.
    public mutating func lift(committing: Bool) -> [TabWalkPayload] {
        guard hasBegun else { return [] }
        let messages = [TabWalkPayload(phase: committing ? .commit : .cancel, row: row)]
        // The key reports back to apps as soon as the finger lifts, so the
        // label never shows a row from a press that already ended.
        self = TabWalkPress()
        return messages
    }
}
#endif
