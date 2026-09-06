import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// One notch of a held delete key's sideways travel.
public enum DeleteScrubStep: Equatable, Sendable {
    case delete
    case restore
}

/// Turns the sideways travel of a held delete key into whole notches.  Both
/// delete keys run on this, so they feel identical and differ only in what the
/// Mac takes off for one notch.
///
/// The count never goes below zero, because a press can only restore what it
/// deleted.  It can still read higher than what the Mac managed to erase; only
/// the Mac knows where the text ran out.
public struct DeleteScrubTracker: Equatable, Sendable {
    /// Notches this press is currently asking for.
    public private(set) var steps = 0
    /// True once any notch has been taken, even if a slide back has since
    /// returned the count to zero.  It is what separates a tap from a slide.
    public private(set) var hasStepped = false
    private var counter: SlideNotchCounter

    public init(sensitivity: Double = 1) {
        counter = SlideNotchCounter(sensitivity: sensitivity)
    }

    /// The notches this travel asks for, in the order they should be sent.
    public mutating func advance(translationX: Double) -> [DeleteScrubStep] {
        // Left erases, and leftward travel is negative.
        let travelled = -counter.advance(to: translationX)
        guard travelled != 0 else { return [] }
        let taken = travelled > 0 ? travelled : -min(-travelled, steps)
        guard taken != 0 else { return [] }
        steps += taken
        hasStepped = true
        return Array(repeating: taken > 0 ? .delete : .restore, count: abs(taken))
    }
}

#if canImport(NewMotionShared)
public extension DeleteScrubStep {
    var phase: DeleteScrubPhase {
        switch self {
        case .delete: return .delete
        case .restore: return .restore
        }
    }
}
#endif
