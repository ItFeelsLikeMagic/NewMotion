import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// One held press of the Command key: where it is aimed on the shared grid,
/// and what it therefore has to tell the Mac.
///
/// The wire says which cell is lit, never how far a finger moved, so this is
/// the only place the two are joined.  It is kept apart from the key view so
/// the whole gesture can be tested without a touch.
public struct KeyPickerPress: Equatable, Sendable {
    /// True once a notch has lit a cell, which is also what separates a press
    /// that has a card open from a plain tap.
    public private(set) var isLit = false
    private var row = 0
    private var column = 0

    public init() {}

    public var cell: HotkeyAction? {
        isLit ? KeyPickerGrid.rows[row][column] : nil
    }

    /// What this notch asks the Mac to do, in the order it goes out.  Nothing
    /// at all when the notch changes nothing, so a slide held against an edge
    /// is silent.
    ///
    /// Overshoot is absorbed rather than banked: a step off the edge, or into
    /// the short last row, is dropped instead of counted, so a step back moves
    /// the highlight at once rather than after retracing every notch spent on
    /// nothing.
    public mutating func notch(_ step: SlideStep) -> [KeyPickerPayload] {
        guard isLit else {
            // The first notch opens the picker on its first cell whichever way
            // the finger went, so no direction can cost a press its card.  The
            // card opens only now, which is what keeps a plain tap free.
            isLit = true
            return [
                KeyPickerPayload(phase: .begin),
                KeyPickerPayload(phase: .highlight, cell: cell)
            ]
        }
        var nextRow = row
        var nextColumn = column
        switch step {
        case .left: nextColumn -= 1
        case .right: nextColumn += 1
        case .up: nextRow -= 1
        case .down: nextRow += 1
        }
        guard KeyPickerGrid.rows.indices.contains(nextRow),
              KeyPickerGrid.rows[nextRow].indices.contains(nextColumn) else { return [] }
        row = nextRow
        column = nextColumn
        return [KeyPickerPayload(phase: .highlight, cell: cell)]
    }

    /// What lifting the finger asks for, or nothing when no card was ever
    /// opened.  A commit carries its own cell, so a highlight lost on the way
    /// costs a stale card rather than the wrong shortcut.
    public mutating func lift(committing: Bool) -> KeyPickerPayload? {
        guard isLit else { return nil }
        let payload = committing
            ? KeyPickerPayload(phase: .commit, cell: cell)
            : KeyPickerPayload(phase: .cancel)
        self = KeyPickerPress()
        return payload
    }
}
#endif
