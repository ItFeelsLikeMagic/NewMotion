import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
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
/// Travel is measured from where the last notch was taken, not from where the
/// finger landed.  That matters at the end of the text: a slide that ran on
/// past the last word spent notches on nothing, and measuring from the start
/// would make the finger pay for all of that dead travel again before the
/// first word came back, which on a phone's width means it never does.  Here
/// one notch of travel is one notch either way, wherever the finger is.
///
/// The count never goes below zero, because a press can only restore what it
/// deleted.  It can still read higher than what the Mac managed to erase; only
/// the Mac knows where the text ran out.
public struct DeleteScrubTracker: Equatable, Sendable {
    /// Travel per notch at 1x.  Half a thumb's width: near enough that a whole
    /// sentence is one comfortable slide, far enough that holding still does
    /// not erase anything.
    public static let baseStepWidth: Double = 24

    public let stepWidth: Double
    /// Notches this press is currently asking for.
    public private(set) var steps = 0
    /// True once any notch has been taken, even if a slide back has since
    /// returned the count to zero.  It is what separates a tap from a slide.
    public private(set) var hasStepped = false
    /// Where the finger was when the last notch of travel was counted.
    private var anchor: Double = 0

    public init(sensitivity: Double = 1) {
        stepWidth = Self.baseStepWidth / min(max(sensitivity, 0.5), 4)
    }

    /// The notches this travel asks for, in the order they should be sent.
    public mutating func advance(translationX: Double) -> [DeleteScrubStep] {
        guard translationX.isFinite else { return [] }
        // Left erases, and leftward travel is negative.
        let travelled = Int(((anchor - translationX) / stepWidth).rounded(.towardZero))
        guard travelled != 0 else { return [] }
        // The anchor follows the finger even where the count cannot, so the
        // next notch is always one notch of travel away.
        anchor -= Double(travelled) * stepWidth
        let taken = travelled > 0 ? travelled : -min(-travelled, steps)
        guard taken != 0 else { return [] }
        steps += taken
        hasStepped = true
        return Array(repeating: taken > 0 ? .delete : .restore, count: abs(taken))
    }
}

#if canImport(PhoneRemoteShared)
public extension DeleteScrubStep {
    var phase: DeleteScrubPhase {
        switch self {
        case .delete: return .delete
        case .restore: return .restore
        }
    }
}
#endif
