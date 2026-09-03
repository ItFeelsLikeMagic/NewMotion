import Foundation

/// Turns the travel of a held key into whole notches along one axis.
///
/// Travel is measured from where the last notch was taken, not from where the
/// finger landed.  That matters wherever a key runs out of things to do: a
/// slide that ran past the end of the text spent notches on nothing, and
/// measuring from the start would make the finger pay for all of that dead
/// travel again before the first notch came back, which on a phone's width
/// means it never does.  Here one notch of travel is one notch either way,
/// wherever the finger is.
public struct SlideNotchCounter: Equatable, Sendable {
    /// Travel per notch at 1x.  Half a thumb's width: near enough that a whole
    /// sentence is one comfortable slide, far enough that holding still does
    /// nothing.
    public static let baseStepWidth: Double = 24

    private let stepWidth: Double
    /// Where the finger was when the last notch was counted.
    private var anchor: Double = 0

    public init(stepWidth: Double = SlideNotchCounter.baseStepWidth, sensitivity: Double = 1) {
        self.stepWidth = stepWidth / min(max(sensitivity, 0.5), 4)
    }

    /// Whole notches this travel adds, signed the way the finger moved.  The
    /// anchor follows the finger even where the caller cannot use every notch,
    /// so the next notch is always one notch of travel away.
    public mutating func advance(to translation: Double) -> Int {
        guard translation.isFinite else { return 0 }
        let travelled = Int(((translation - anchor) / stepWidth).rounded(.towardZero))
        guard travelled != 0 else { return 0 }
        anchor += Double(travelled) * stepWidth
        return travelled
    }
}
