import Foundation

/// What one notch of the delete key takes off, and how a thumb changes it.
/// Sliding up puts the key in word mode, sliding down puts it back on
/// characters.  It is deliberately far to travel: the same press also slides
/// sideways to erase, so a wobble on the way across must not change what the
/// key is deleting.
///
/// The mode only lasts for the press that set it: every new press starts back
/// on characters, so the key never silently deletes a word because of how the
/// last press ended.
public struct DeleteGranularityLatch: Equatable, Sendable {
    /// Travel that flips the mode.  Most of the height of a key, so the
    /// finger has to leave the one it is on.
    public static let travel: Double = 44

    public private(set) var isWord: Bool
    /// Where the finger was when the mode last changed.  Measuring from there
    /// rather than from the touch means the way back is always one full
    /// travel, however far the slide overshot.
    private var anchor: Double = 0

    public init(isWord: Bool = false) {
        self.isWord = isWord
    }

    /// Call at the start of a press: the finger is at zero again and the mode
    /// is back on characters.
    public mutating func reset() {
        isWord = false
        anchor = 0
    }

    /// True when this travel flipped the mode.
    public mutating func advance(translationY: Double) -> Bool {
        guard translationY.isFinite else { return false }
        // Up the screen is negative.
        if !isWord, translationY <= anchor - Self.travel {
            isWord = true
        } else if isWord, translationY >= anchor + Self.travel {
            isWord = false
        } else {
            return false
        }
        anchor = translationY
        return true
    }
}
