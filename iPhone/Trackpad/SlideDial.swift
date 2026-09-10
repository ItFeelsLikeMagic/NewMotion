import Foundation

/// The vertical dial on a held key: sliding up turns it one way, sliding down
/// the other, and it stops at the ends.  It is what lets one key be two or
/// three keys without a second key on the glass.
///
/// A position is deliberately far to travel: the same press also slides
/// sideways to do the key's real work, so a wobble on the way across must not
/// change what the key is doing.  The travel is counted from the last position
/// it settled in, so the way back is always one full turn however far the
/// slide overshot, and a dial held at an end comes back on the first turn.
///
/// The setting only lasts for the press that made it: every new press starts
/// back at rest, so a key never silently does the other thing because of how
/// the last press ended.
public struct SlideDial: Equatable, Sendable {
    /// Travel per position.  Most of the height of a key, so the finger has to
    /// leave the one it is on.
    public static let travel: Double = 44

    /// Where the dial is, counting up from rest: 1 is one slide up, -1 is one
    /// slide down.  What those mean is the key's business.
    public private(set) var position = 0

    private let range: ClosedRange<Int>
    private var counter = SlideNotchCounter(stepWidth: SlideDial.travel)

    public init(range: ClosedRange<Int>) {
        self.range = range
    }

    /// True when this travel turned the dial.
    public mutating func advance(translationY: Double) -> Bool {
        // Up the screen is negative, and up turns the dial forwards.
        let turned = -counter.advance(to: translationY)
        guard turned != 0 else { return false }
        let next = min(max(position + turned, range.lowerBound), range.upperBound)
        guard next != position else { return false }
        position = next
        return true
    }
}
