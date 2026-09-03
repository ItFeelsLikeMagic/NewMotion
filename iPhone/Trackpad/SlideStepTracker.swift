import Foundation

/// One notch of a held key's travel, in the direction the finger moved.
public enum SlideStep: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// Turns a held key's travel into steps on both axes, on the same notch as the
/// delete keys so every hold-and-drag key reads as one gesture to the hand.
///
/// The axes count separately, so a diagonal drag steps both ways at once.
/// Nothing is clamped either: a step the other way undoes the one before it,
/// so the finger can always take a step back.
public struct SlideStepTracker: Equatable, Sendable {
    private var horizontal: SlideNotchCounter
    private var vertical: SlideNotchCounter

    public init(sensitivity: Double = 1) {
        horizontal = SlideNotchCounter(sensitivity: sensitivity)
        vertical = SlideNotchCounter(sensitivity: sensitivity)
    }

    /// The steps this travel asks for, in the order they should be sent.
    public mutating func advance(translationX: Double, translationY: Double) -> [SlideStep] {
        let x = horizontal.advance(to: translationX)
        let y = vertical.advance(to: translationY)
        return Array(repeating: x < 0 ? .left : .right, count: abs(x))
            + Array(repeating: y < 0 ? .up : .down, count: abs(y))
    }
}
