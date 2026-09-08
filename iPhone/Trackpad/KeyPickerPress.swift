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
    /// True once the key has gone down, which is what a lift has to close.
    public private(set) var hasBegun = false
    private var row = 0
    private var column = 0

    public init() {}

    /// Where the press is aimed.  A press always has an aim: the grid's first
    /// cell is Cancel, so a finger that never moves is aimed at doing nothing.
    public var cell: KeyPickerCell {
        KeyPickerGrid.rows[row][column]
    }

    /// Touch-down.  The card opens here with Cancel lit, so it is already on
    /// the Mac screen by the time the finger starts to move, and a press
    /// abandoned there fires nothing.  `begin` carries no cell for the same
    /// reason a Cancel highlight does not: no cell is how the wire says it.
    public mutating func begin() -> KeyPickerPayload? {
        guard !hasBegun else { return nil }
        hasBegun = true
        return KeyPickerPayload(phase: .begin)
    }

    /// What the Mac is told again while the key is held but still.  A held key
    /// that has stopped moving is silent, and the Mac closes a card that has
    /// gone quiet, so the lit cell is said again every couple of seconds.
    public var keepalive: KeyPickerPayload? {
        guard hasBegun else { return nil }
        return KeyPickerPayload(phase: .highlight, cell: cell.hotkey)
    }

    /// What this notch asks the Mac to do.  Nothing at all when the notch
    /// changes nothing, so a slide held against an edge is silent.
    ///
    /// Overshoot is absorbed rather than banked: a step off the edge, or into
    /// a row that is a cell shorter, is dropped instead of counted, so a step
    /// back moves the highlight at once rather than after retracing every
    /// notch spent on nothing.
    public mutating func notch(_ step: SlideStep) -> [KeyPickerPayload] {
        guard hasBegun else { return [] }
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
        return [KeyPickerPayload(phase: .highlight, cell: cell.hotkey)]
    }

    /// What lifting the finger asks for.  A press always closes the card it
    /// opened, and a commit carries its own cell, so a highlight lost on the
    /// way costs a stale card rather than the wrong shortcut.  A commit that
    /// names no cell lifted on Cancel: the Mac closes the card and fires
    /// nothing.
    public mutating func lift(committing: Bool) -> KeyPickerPayload? {
        guard hasBegun else { return nil }
        let payload = committing
            ? KeyPickerPayload(phase: .commit, cell: cell.hotkey)
            : KeyPickerPayload(phase: .cancel)
        self = KeyPickerPress()
        return payload
    }
}
#endif
