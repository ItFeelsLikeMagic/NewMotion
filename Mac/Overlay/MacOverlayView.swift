#if os(macOS)
import AppKit
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The card itself: one thing at a time, sized to what it says, centred in a
/// pane of one fixed size. Every number it draws from lives in
/// `MacOverlayStyle`, so the menu bar can tune the look while a card is up.
struct MacOverlayView: View {
    @ObservedObject var shown: MacOverlayContentBox

    private var style: MacOverlayStyle { shown.style }

    var body: some View {
        content
            .padding(.horizontal, MacOverlayStyle.cardPadding.width)
            .padding(.vertical, MacOverlayStyle.cardPadding.height)
            .background(cardBackground)
            .fixedSize()
            .animation(style.fade, value: shape)
            .frame(width: style.panelSize.width, height: style.panelSize.height)
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
        VStack(alignment: .leading, spacing: CGFloat(style.tileSpacing)) {
            ForEach(Array(KeyPickerGrid.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: CGFloat(style.tileSpacing)) {
                    ForEach(row, id: \.self) { cell in
                        tile(
                            cap: KeyPickerGrid.keyCap(for: cell),
                            name: KeyPickerGrid.displayName(for: cell) ?? "",
                            isLit: cell.hotkey == lit
                        )
                    }
                }
                .padding(.leading, style.rowOffset(index))
            }
        }
    }

    /// The same tiles as the picker, because it is the same gesture: hold a key
    /// and slide. Stacked the way the finger moves: up on the phone is Word, so
    /// Word sits on top. And a line saying what across does, since the card is
    /// up before the finger has moved and that is the moment the reminder is
    /// worth anything. It gets a slab of its own; the card behind it is clear.
    private func deleteUnits(lit: DeleteScrubGranularity) -> some View {
        VStack(spacing: CGFloat(style.tileSpacing)) {
            ForEach(DeleteScrubGranularity.allCases.reversed(), id: \.self) { unit in
                tile(cap: nil, name: Self.unitName(unit), isLit: unit == lit)
            }
            if style.captionOnDeleteCard {
                Text("Slide left to erase, right to restore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .modifier(Slab(shape: Capsule(), isLit: false, style: style))
            }
        }
    }

    /// One key of the grid: the cap large, what it does small underneath.
    private func tile(cap: String?, name: String, isLit: Bool) -> some View {
        VStack(spacing: 2) {
            if let cap {
                Text(cap)
                    .font(.system(size: style.capFontSize, weight: style.capWeight, design: .rounded))
                if style.showsNames {
                    Text(name)
                        .font(.system(size: style.nameFontSize))
                        .foregroundStyle(nameColour(isLit: isLit))
                }
            } else {
                Text(name)
                    .font(.system(size: style.plainFontSize, weight: style.capWeight, design: .rounded))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 6)
        .frame(width: style.tileSide, height: style.tileSide)
        .foregroundStyle(isLit && style.tintsLitKey ? Color.white : Color.primary)
        .shadow(
            color: style.textShadow ? Color.black.opacity(0.45) : .clear,
            radius: style.textShadow ? 2 : 0,
            y: style.textShadow ? 1 : 0
        )
        .modifier(Slab(
            shape: RoundedRectangle(cornerRadius: style.tileCorner, style: .continuous),
            isLit: isLit,
            style: style
        ))
    }

    /// The name under the cap is quieter than the cap itself, and on a tinted
    /// key it has to stay white or it drops out of the accent colour.
    private func nameColour(isLit: Bool) -> Color {
        guard isLit else { return .secondary }
        return style.tintsLitKey ? Color.white.opacity(0.85) : Color.primary.opacity(0.7)
    }

    /// Liquid Glass where the Mac has it, so the keys sit on the wallpaper the
    /// way the system's own floating controls do; a material slab with a
    /// hairline where it does not, and wherever the style asks for one.  The
    /// lit key is the glass tinted, not a flat fill, so it keeps the same edge
    /// as its neighbours; untinted it is a dim wash and a heavier edge, which
    /// survives a wallpaper the accent colour is already in.
    private struct Slab<S: InsettableShape>: ViewModifier {
        let shape: S
        let isLit: Bool
        let style: MacOverlayStyle

        @ViewBuilder
        func body(content: Content) -> some View {
            // Both fills sit between the glass and the letters: a scrim behind
            // the glass would be hidden by it and do nothing for legibility.
            // The window colour, not a fixed one, so the scrim stays under the
            // type in both appearances instead of on top of it in one.
            let inner = content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(style.backing)))
                .background(shape.fill(Color.primary.opacity(wash)))
            if style.glass != .frosted, #available(macOS 26, *) {
                // The glass is its own layer under the scrim rather than an
                // effect on the tile, so it can be faded without the letters.
                // It is also why the tiles share no glass container: a
                // container draws its glass over everything else inside it,
                // and took the letters with it.
                inner.background(
                    shape.fill(.clear)
                        .glassEffect(glass, in: shape)
                        .opacity(style.glassOpacity)
                )
            } else if isLit, style.tintsLitKey {
                inner.background(shape.fill(Color.accentColor))
            } else {
                inner
                    .background(shape.fill(.regularMaterial))
                    .overlay(shape.strokeBorder(edge, lineWidth: isLit ? 2 : 1))
            }
        }

        @available(macOS 26, *)
        private var glass: Glass {
            let base: Glass = style.glass == .regular ? .regular : .clear
            return isLit && style.tintsLitKey ? base.tint(Color.accentColor) : base
        }

        private var wash: Double {
            isLit && !style.tintsLitKey ? 0.18 : 0
        }

        private var edge: Color {
            Color.primary.opacity(isLit ? 0.5 : 0.12)
        }
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
            .frame(width: MacOverlayStyle.maximumWidth, alignment: .leading)
    }
}
#endif
