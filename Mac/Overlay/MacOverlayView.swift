#if os(macOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The card itself: one thing at a time, sized to what it says, centred in a
/// pane of one fixed size.
struct MacOverlayView: View {
    /// Keycaps, not labels: the picker is read out of the corner of an eye
    /// while a thumb is already moving, so a tile is big enough to hit with a
    /// glance and square enough to read as a key.
    private static let tileSide: CGFloat = 84
    private static let tileCorner: CGFloat = 18
    private static let tileSpacing: CGFloat = 10
    private static let capFontSize: CGFloat = 30
    /// A tile with no key of its own carries its whole name instead, so its
    /// type has to fit across the square rather than sit on one line of it.
    private static let plainFontSize: CGFloat = 18
    private static let cardPadding = CGSize(width: 18, height: 14)
    /// How far each row of the grid starts in from the one above, in tiles.
    /// A keyboard's rows are offset like this, and the offset is most of what
    /// tells a hand which row it is looking at.
    private static let rowOffsets: [CGFloat] = [0, 0.25, 0.75]
    /// Clear, click-through room around the card, so the panel never has to be
    /// measured or resized: measuring it meant reading a view that was still
    /// animating, and the first card of a session came up the size of an empty
    /// one. The spare room costs nothing.
    private static let spareRoom: CGFloat = 60
    /// The pane the card floats in, fixed, and taken from the picker because
    /// the picker is the largest thing the card can be.
    static let panelSize = CGSize(
        width: max(pickerSize.width, maximumWidth) + 2 * (cardPadding.width + spareRoom),
        height: pickerSize.height + 2 * (cardPadding.height + spareRoom)
    )
    /// Long enough for a line of dictation without reaching across a display.
    private static let maximumWidth: CGFloat = 460
    private static let fade: Animation = .easeInOut(duration: 0.12)

    @ObservedObject var shown: MacOverlayContentBox

    var body: some View {
        content
            .padding(.horizontal, Self.cardPadding.width)
            .padding(.vertical, Self.cardPadding.height)
            .background(cardBackground)
            .fixedSize()
            .animation(Self.fade, value: shape)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
    }

    /// Only the cards that are text get a slab behind them, because only text
    /// is unreadable on a wallpaper. The tiles carry their own material, and a
    /// second one behind them would box in a grid that reads better floating.
    @ViewBuilder
    private var cardBackground: some View {
        switch shown.content {
        case .transcript, .hint:
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
        case .nothing, .picker, .delete:
            EmptyView()
        }
    }

    /// What the fade is allowed to notice.  A card arriving or leaving, and a
    /// picker lighting a different key, are worth a fade; a transcript revising
    /// its words ten times a second is not, and animating those smears them.
    /// An empty transcript is the same shape as a full one, so the placeholder
    /// does not fade out under the first word it is waiting for.
    private enum CardShape: Equatable {
        case nothing
        case picker(HotkeyAction?)
        case delete(DeleteScrubGranularity)
        case transcript
        case hint(String)
    }

    private var shape: CardShape {
        switch shown.content {
        case .nothing: return .nothing
        case let .picker(cell): return .picker(cell)
        case let .delete(granularity): return .delete(granularity)
        case .transcript: return .transcript
        case let .hint(text): return .hint(text)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shown.content {
        case .nothing:
            EmptyView()
        case let .picker(cell):
            grid(lit: cell)
        case let .delete(granularity):
            deleteUnits(lit: granularity)
        case let .transcript(text):
            transcript(text)
        case let .hint(text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// `lit` is the hotkey the phone named, and no hotkey means the Cancel
    /// cell, which is what an open card starts on.
    private func grid(lit: HotkeyAction?) -> some View {
        VStack(alignment: .leading, spacing: Self.tileSpacing) {
            ForEach(Array(KeyPickerGrid.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: Self.tileSpacing) {
                    ForEach(row, id: \.self) { cell in
                        tile(
                            cap: KeyPickerGrid.keyCap(for: cell),
                            name: KeyPickerGrid.displayName(for: cell) ?? "",
                            isLit: cell.hotkey == lit
                        )
                    }
                }
                .padding(.leading, Self.rowOffset(index))
            }
        }
    }

    /// The same tiles as the picker, because it is the same gesture: hold a key
    /// and slide. Stacked the way the finger moves: up on the phone is Word, so
    /// Word sits on top. And a line saying what across does, since the card is
    /// up before the finger has moved and that is the moment the reminder is
    /// worth anything. It gets a slab of its own; the card behind it is clear.
    private func deleteUnits(lit: DeleteScrubGranularity) -> some View {
        VStack(spacing: Self.tileSpacing) {
            VStack(spacing: Self.tileSpacing) {
                ForEach(DeleteScrubGranularity.allCases.reversed(), id: \.self) { unit in
                    tile(cap: nil, name: Self.unitName(unit), isLit: unit == lit)
                }
            }
            Text("Slide left to erase, right to restore")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial))
        }
    }

    /// One key of the grid: the cap large, what it does small underneath. The
    /// unlit fill is a material rather than a tint so a tile stays a tile over
    /// a white document and over a photograph.
    private func tile(cap: String?, name: String, isLit: Bool) -> some View {
        VStack(spacing: 2) {
            if let cap {
                Text(cap)
                    .font(.system(size: Self.capFontSize, weight: .medium, design: .rounded))
                Text(name)
                    .font(.caption)
                    .foregroundStyle(isLit ? Color.white.opacity(0.85) : Color.secondary)
            } else {
                Text(name)
                    .font(.system(size: Self.plainFontSize, weight: .medium, design: .rounded))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 6)
        .frame(width: Self.tileSide, height: Self.tileSide)
        .foregroundStyle(isLit ? Color.white : Color.primary)
        .background(tileFill(isLit: isLit))
        .overlay(
            RoundedRectangle(cornerRadius: Self.tileCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(isLit ? 0 : 0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tileFill(isLit: Bool) -> some View {
        if isLit {
            RoundedRectangle(cornerRadius: Self.tileCorner, style: .continuous)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: Self.tileCorner, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private static func rowOffset(_ index: Int) -> CGFloat {
        guard index < rowOffsets.count else { return 0 }
        return tileSide * rowOffsets[index]
    }

    /// The grid laid out, so the panel can be sized from the same numbers that
    /// draw it instead of a measurement taken while it animates.
    private static var pickerSize: CGSize {
        let rows = KeyPickerGrid.rows
        let widths = rows.enumerated().map { index, row in
            rowOffset(index) + span(rows: row.count)
        }
        return CGSize(width: widths.max() ?? 0, height: span(rows: rows.count))
    }

    private static func span(rows count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * tileSide + CGFloat(count - 1) * tileSpacing
    }

    private static func unitName(_ unit: DeleteScrubGranularity) -> String {
        switch unit {
        case .character: return "Character"
        case .word: return "Word"
        }
    }

    /// Truncated at the head, so the newest words are the ones still on
    /// screen: this is a glance at the tail of a sentence, not a transcript.
    /// The width is fixed rather than fitted, so the card does not shuffle
    /// sideways on every partial. Empty means the key is down and the
    /// recogniser has nothing yet, which is worth saying out loud.
    private func transcript(_ text: String) -> some View {
        Text(text.isEmpty ? "Listening…" : text)
            .font(.title3)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(width: Self.maximumWidth, alignment: .leading)
    }
}
#endif
