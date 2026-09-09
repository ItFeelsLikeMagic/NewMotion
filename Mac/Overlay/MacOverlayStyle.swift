#if os(macOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Every number the chord card is drawn from. It lives apart from the view so
/// the menu bar can tune it while a card is on screen, and so the panel can be
/// sized from the same numbers that draw the grid.
struct MacOverlayStyle: Codable, Equatable, Sendable {
    /// What fills a tile. `clear` and `regular` are Liquid Glass on the Macs
    /// that have it; `frosted` is the material slab with a hairline, which is
    /// all a Mac before 26 can draw and is also the most solid of the three
    /// over a wallpaper that eats type.
    enum GlassKind: String, Codable, CaseIterable, Sendable, Identifiable {
        case clear
        case regular
        case frosted

        var id: String { rawValue }

        var label: String {
            switch self {
            case .clear: return "Clear"
            case .regular: return "Regular"
            case .frosted: return "Frosted"
            }
        }
    }

    var glass: GlassKind = .clear
    /// The lit key as tinted glass, which keeps the same edge as its
    /// neighbours. Off trades that for a plain dim highlight, for an accent
    /// colour that disappears into the wallpaper behind it.
    var tintsLitKey = true
    /// How much of the glass is drawn at all. Apple's glass comes in two
    /// strengths and no dial, so this fades the whole pane, edge and blur
    /// together, towards nothing; the letters stay solid.
    var glassOpacity: Double = 0.5
    /// A scrim between the glass and the letters. Clear glass shows whatever
    /// is behind it straight through, and some wallpapers swallow the type.
    var backing: Double = 0.15
    /// Keycaps, not labels: the picker is read out of the corner of an eye
    /// while a thumb is already moving, so a tile is big enough to hit with a
    /// glance and square enough to read as a key.
    var tileSide: Double = 100
    var tileCorner: Double = 15
    var tileSpacing: Double = 10
    var capFontSize: Double = 30
    /// The small line under the cap saying what the key does.
    var showsNames = false
    var nameFontSize: Double = 11
    var boldCaps = false
    /// A soft shadow under the type, which is what makes a clear tile legible
    /// without a scrim behind it.
    var textShadow = false
    /// How far each row of the grid starts in from the one above, in tiles:
    /// row one by this much, row two by three times it. A keyboard's rows are
    /// offset like this, and the offset is most of what tells a hand which row
    /// it is looking at.
    var stagger: Double = 0.25
    var fadeDuration: Double = 0.12
    /// The line under the delete card saying what sliding across does.
    var captionOnDeleteCard = true

    /// The tuned look, and what a decode that fails falls back to.
    static let standard = MacOverlayStyle()

    static let glassOpacityRange: ClosedRange<Double> = 0...1
    static let backingRange: ClosedRange<Double> = 0...0.7
    static let tileSideRange: ClosedRange<Double> = 56...128
    static let tileCornerRange: ClosedRange<Double> = 4...40
    static let tileSpacingRange: ClosedRange<Double> = 2...28
    static let capFontSizeRange: ClosedRange<Double> = 16...56
    static let nameFontSizeRange: ClosedRange<Double> = 9...16
    static let staggerRange: ClosedRange<Double> = 0...0.6
    static let fadeDurationRange: ClosedRange<Double> = 0...0.4

    static let cardPadding = CGSize(width: 18, height: 14)
    /// Clear, click-through room around the card, so the card itself never has
    /// to be measured: measuring it meant reading a view that was still
    /// animating, and the first card of a session came up the size of an empty
    /// one. The spare room costs nothing, and the panel is only resized when
    /// someone moves a slider.
    static let spareRoom: CGFloat = 60
    /// Long enough for a line of dictation without reaching across a display.
    static let maximumWidth: CGFloat = 460

    /// The pane the card floats in, taken from the picker because the picker
    /// is the largest thing the card can be.
    var panelSize: CGSize {
        let grid = pickerSize
        return CGSize(
            width: max(grid.width, Self.maximumWidth) + 2 * (Self.cardPadding.width + Self.spareRoom),
            height: grid.height + 2 * (Self.cardPadding.height + Self.spareRoom)
        )
    }

    /// A tile with no key of its own carries its whole name instead, so its
    /// type has to fit across the square rather than sit on one line of it.
    var plainFontSize: Double { capFontSize * 0.6 }

    var capWeight: Font.Weight { boldCaps ? .bold : .medium }

    var fade: Animation { .easeInOut(duration: fadeDuration) }

    /// How far row `index` starts in from the left edge of the grid.
    func rowOffset(_ index: Int) -> CGFloat {
        // Cancel sits alone above the keys, flush left like the escape key it
        // stands for, so the stepping starts under it.
        let offsets: [Double] = [0, 0, stagger, 3 * stagger]
        guard index < offsets.count else { return 0 }
        return CGFloat(tileSide * offsets[index])
    }

    /// The grid laid out from the same numbers that draw it, rather than a
    /// measurement taken while it animates.
    private var pickerSize: CGSize {
        let rows = KeyPickerGrid.rows
        let widths = rows.enumerated().map { index, row in
            rowOffset(index) + span(count: row.count)
        }
        return CGSize(width: widths.max() ?? 0, height: span(count: rows.count))
    }

    private func span(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(Double(count) * tileSide + Double(count - 1) * tileSpacing)
    }
}

/// Where the tuned style is kept between launches. Written out whole on every
/// change: it is a few hundred bytes, and the alternative is losing an
/// afternoon of tuning to a quit.
@MainActor
final class MacOverlayStyleStore: ObservableObject {
    private static let key = "overlayStyle"

    @Published var style: MacOverlayStyle {
        didSet {
            guard style != oldValue else { return }
            save()
            onChange?(style)
        }
    }

    /// The card on screen, which has to follow a slider being dragged rather
    /// than wait for the next time something asks to be drawn.
    var onChange: ((MacOverlayStyle) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Anything unreadable was written by a build with different fields.
        // The defaults are a better answer than refusing to draw a card.
        let stored = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(MacOverlayStyle.self, from: $0) }
        self.style = stored ?? .standard
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(style) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
#endif
