#if os(macOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Every number the chord card is drawn from. These were a panel of sliders
/// while the look was being found; they are settled now, and live apart from
/// the view so the panel can be sized from the same numbers that draw the grid.
enum MacOverlayStyle {
    /// How much of a tile's glass is drawn at all. Apple's glass comes in two
    /// strengths and no dial, so this fades a tile, edge and blur together,
    /// towards nothing; the letters stay solid.
    static let glassOpacity: Double = 0.5
    /// A scrim between a tile's glass and its letters. Clear glass shows
    /// whatever is behind it straight through, and some wallpapers swallow the
    /// type.
    static let backing: Double = 0.15
    /// Keycaps, not labels: the picker is read out of the corner of an eye
    /// while a thumb is already moving, so a tile is big enough to hit with a
    /// glance and square enough to read as a key.
    static let tileSide: CGFloat = 100
    static let tileCorner: CGFloat = 15
    static let tileSpacing: CGFloat = 10
    static let capFontSize: CGFloat = 30
    /// How far each row of the grid starts in from the one above, in tiles:
    /// row one by this much, row two by three times it. A keyboard's rows are
    /// offset like this, and the offset is most of what tells a hand which row
    /// it is looking at.
    static let stagger: CGFloat = 0.25
    static let fadeDuration: TimeInterval = 0.12

    /// The one pane every card sits on. Round enough to read as a floating
    /// sheet rather than a tile grown large, the way the app switcher does.
    static let cardCorner: CGFloat = 24
    /// How wide the band of glass at the sheet's edge is; the middle is bare.
    static let rimWidth: CGFloat = 14
    /// Room between the content and the pane's edge. The middle of the glass
    /// is almost nothing to look at; the rim is the whole effect, so the card
    /// has to leave it somewhere to be.
    static let cardPadding: CGFloat = 22
    /// Clear, click-through room around the card, so the card itself never has
    /// to be measured: measuring it meant reading a view that was still
    /// animating, and the first card of a session came up the size of an empty
    /// one. The spare room costs nothing, and the panel is never resized.
    static let spareRoom: CGFloat = 60
    /// Long enough for a line of dictation without reaching across a display.
    static let maximumWidth: CGFloat = 460

    /// The pane the card floats in, taken from the picker because the picker
    /// is the largest thing the card can be.
    static let panelSize = CGSize(
        width: max(pickerSize.width, maximumWidth) + 2 * (cardPadding + spareRoom),
        height: pickerSize.height + 2 * (cardPadding + spareRoom)
    )

    /// A tile with no key of its own carries its whole name instead, so its
    /// type has to fit across the square rather than sit on one line of it.
    static let plainFontSize: CGFloat = capFontSize * 0.6

    static var capWeight: Font.Weight { .medium }

    static var fade: Animation { .easeInOut(duration: fadeDuration) }

    /// How far row `index` starts in from the left edge of the grid.
    static func rowOffset(_ index: Int) -> CGFloat {
        // Cancel sits alone above the keys, flush left like the escape key it
        // stands for, so the stepping starts under it.
        let offsets: [CGFloat] = [0, 0, stagger, 3 * stagger]
        guard index < offsets.count else { return 0 }
        return tileSide * offsets[index]
    }

    /// The grid laid out from the same numbers that draw it, rather than a
    /// measurement taken while it animates.
    private static let pickerSize: CGSize = {
        let rows = KeyPickerGrid.rows
        let widths = rows.enumerated().map { index, row in
            rowOffset(index) + span(count: row.count)
        }
        return CGSize(width: widths.max() ?? 0, height: span(count: rows.count))
    }()

    private static func span(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * tileSide + CGFloat(count - 1) * tileSpacing
    }
}
#endif
