#if os(macOS)
import AppKit
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The card itself: one thing at a time, sized to what it says, centred in a
/// pane of one fixed size. Every number it draws from lives in
/// `MacOverlayStyle`.
struct MacOverlayView: View {
    @ObservedObject var shown: MacOverlayContentBox

    var body: some View {
        content
            .padding(MacOverlayStyle.cardPadding)
            .background(pane)
            .fixedSize()
            .animation(MacOverlayStyle.fade, value: shape)
            .frame(width: MacOverlayStyle.panelSize.width, height: MacOverlayStyle.panelSize.height)
    }

    /// One sheet of glass behind the whole card, the way the app switcher sits
    /// over a desktop: nothing at all through the middle, and a rim that bends
    /// and catches the light. Apple's glass blurs and greys whatever it covers,
    /// even the clear kind, so it is kept to a ring at the edge, masked away
    /// from the middle, with a highlight stroke over it for the gloss. It is a
    /// background, not a container: a glass container draws its own glass over
    /// everything inside it, and took the tiles' letters with it.
    @ViewBuilder
    private var pane: some View {
        let shape = RoundedRectangle(cornerRadius: MacOverlayStyle.cardCorner, style: .continuous)
        switch shown.content {
        case .nothing:
            EmptyView()
        case .picker, .arrows, .delete, .transcript, .hint:
            ZStack {
                if #available(macOS 26, *) {
                    shape.fill(.clear)
                        .glassEffect(.clear, in: shape)
                        .mask(rimMask(shape))
                } else {
                    shape.fill(.ultraThinMaterial).mask(rimMask(shape))
                }
                shape.fill(Color.white.opacity(0.03))
                shape.strokeBorder(Self.gloss, lineWidth: 1.2)
                shape.inset(by: 1.2).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.6)
            }
        }
    }

    /// Light from the top left, as on every Apple pane: bright along the top
    /// edge, dim down the right, a little back at the bottom.
    private static let gloss = LinearGradient(
        colors: [Color.white.opacity(0.75), Color.white.opacity(0.18), Color.white.opacity(0.45)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Opaque at the edge, gone `rimWidth` in, with a soft falloff so the
    /// glass fades into the clear middle rather than ending on a line.
    private func rimMask(_ shape: RoundedRectangle) -> some View {
        shape.fill(Color.black)
            .overlay(shape.inset(by: MacOverlayStyle.rimWidth).fill(Color.black).blendMode(.destinationOut))
            .compositingGroup()
            .blur(radius: MacOverlayStyle.rimWidth / 2)
    }

    /// What the fade is allowed to notice.  A card arriving or leaving, and a
    /// picker lighting a different key, are worth a fade; a transcript revising
    /// its words ten times a second is not, and animating those smears them.
    /// An empty transcript is the same shape as a full one, so the placeholder
    /// does not fade out under the first word it is waiting for.  The armed
    /// bar is part of the shape: it arrives and leaves with the finger, which
    /// is a card changing size and worth the fade.
    private enum CardShape: Equatable {
        case nothing
        case picker(HotkeyAction?)
        case arrows(HotkeyAction?)
        case delete(DeleteScrubGranularity)
        case transcript(TranscriptPreviewArmed)
        case hint(String)
    }

    private var shape: CardShape {
        switch shown.content {
        case .nothing: return .nothing
        case let .picker(cell): return .picker(cell)
        case let .arrows(lit): return .arrows(lit)
        case let .delete(granularity): return .delete(granularity)
        case let .transcript(_, armed): return .transcript(armed)
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
        case let .arrows(lit):
            arrows(lit: lit)
        case let .delete(granularity):
            deleteUnits(lit: granularity)
        case let .transcript(text, armed):
            transcript(text, armed: armed)
        case let .hint(text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// `lit` is the hotkey the phone named, and no hotkey means the Cancel
    /// cell, which is what an open card starts on.
    private func grid(lit: HotkeyAction?) -> some View {
        VStack(alignment: .leading, spacing: MacOverlayStyle.tileSpacing) {
            ForEach(Array(KeyPickerGrid.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: MacOverlayStyle.tileSpacing) {
                    ForEach(row, id: \.self) { cell in
                        tile(
                            cap: cell == .cancel ? .symbol("trash.fill") : KeyPickerGrid.keyCap(for: cell).map(Cap.key),
                            name: KeyPickerGrid.displayName(for: cell) ?? "",
                            isLit: cell.hotkey == lit
                        )
                    }
                }
                .padding(.leading, MacOverlayStyle.rowOffset(index))
            }
        }
    }

    /// The keyboard's own inverted T, so a card caught out of the corner of an
    /// eye reads as the arrow keys rather than as a list of directions. The
    /// same tiles as the picker, because it is the same gesture: hold a key and
    /// slide. Nothing is lit between notches; the arrow that just went lights
    /// for long enough to be seen and no longer.
    private func arrows(lit: HotkeyAction?) -> some View {
        VStack(spacing: MacOverlayStyle.tileSpacing) {
            tile(cap: .key("\u{2191}"), name: "Up", isLit: lit == .arrowUp)
            HStack(spacing: MacOverlayStyle.tileSpacing) {
                tile(cap: .key("\u{2190}"), name: "Left", isLit: lit == .arrowLeft)
                tile(cap: .key("\u{2193}"), name: "Down", isLit: lit == .arrowDown)
                tile(cap: .key("\u{2192}"), name: "Right", isLit: lit == .arrowRight)
            }
        }
    }

    /// The same tiles as the picker, because it is the same gesture: hold a key
    /// and slide. Stacked the way the finger moves: up on the phone is Word, so
    /// Word sits on top. And a line saying what across does, since the card is
    /// up before the finger has moved and that is the moment the reminder is
    /// worth anything. It gets a slab of its own, so it reads as another key
    /// rather than as writing on the pane.
    private func deleteUnits(lit: DeleteScrubGranularity) -> some View {
        VStack(spacing: MacOverlayStyle.tileSpacing) {
            ForEach(DeleteScrubGranularity.allCases.reversed(), id: \.self) { unit in
                tile(cap: nil, name: Self.unitName(unit), isLit: unit == lit)
            }
            Text("Slide left to erase, right to restore")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .modifier(Slab(shape: Capsule(), isLit: false))
        }
    }

    /// One key of the grid.
    /// What sits large on a tile: a key as printed on the keyboard, or a
    /// picture for a cell that is no key at all.  Cancel is the bin, not
    /// "esc": it throws the chord away rather than sending anything.  A tile
    /// with neither carries its name instead.
    private enum Cap {
        case key(String)
        case symbol(String)
    }

    private func tile(cap: Cap?, name: String, isLit: Bool) -> some View {
        Group {
            if let cap {
                switch cap {
                case let .key(key):
                    Text(key)
                        .font(.system(size: MacOverlayStyle.capFontSize, weight: MacOverlayStyle.capWeight, design: .rounded))
                case let .symbol(symbol):
                    Image(systemName: symbol)
                        .font(.system(size: MacOverlayStyle.capFontSize * 0.85, weight: MacOverlayStyle.capWeight))
                }
            } else {
                Text(name)
                    .font(.system(size: MacOverlayStyle.plainFontSize, weight: MacOverlayStyle.capWeight, design: .rounded))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 6)
        .frame(width: MacOverlayStyle.tileSide, height: MacOverlayStyle.tileSide)
        .foregroundStyle(isLit ? Color.white : Color.primary)
        .modifier(Slab(
            shape: RoundedRectangle(cornerRadius: MacOverlayStyle.tileCorner, style: .continuous),
            isLit: isLit
        ))
    }

    /// Liquid Glass where the Mac has it, so the keys sit on the wallpaper the
    /// way the system's own floating controls do; a material slab with a
    /// hairline where it does not.  The lit key is the glass tinted, not a flat
    /// fill, so it keeps the same edge as its neighbours.
    private struct Slab<S: InsettableShape>: ViewModifier {
        let shape: S
        let isLit: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            // The scrim sits between the glass and the letters: behind the
            // glass it would be hidden and do nothing for legibility. The
            // window colour, not a fixed one, so it stays under the type in
            // both appearances instead of on top of it in one.
            let inner = content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(MacOverlayStyle.backing)))
            if #available(macOS 26, *) {
                // The glass is its own layer under the scrim rather than an
                // effect on the tile, so it can be faded without the letters.
                // It is also why the tiles share no glass container: a
                // container draws its glass over everything else inside it,
                // and took the letters with it.
                inner.background(
                    shape.fill(.clear)
                        .glassEffect(glass, in: shape)
                        .opacity(MacOverlayStyle.glassOpacity)
                )
            } else if isLit {
                inner.background(shape.fill(Color.accentColor))
            } else {
                inner
                    .background(shape.fill(.regularMaterial))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            }
        }

        @available(macOS 26, *)
        private var glass: Glass {
            isLit ? Glass.clear.tint(Color.accentColor) : .clear
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
    ///
    /// The phone's Send and Cancel bars sit above and below the words the
    /// way they sit around the talk button, so the card is also the hint that
    /// sliding up or down does something, and the armed one lights the way a
    /// picked key does.
    private func transcript(_ text: String, armed: TranscriptPreviewArmed) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            bar("Send", symbol: "return", colour: .green, isLit: armed == .send)
            // The words sit in a slab of their own, like the bars, so the
            // card reads as three keys with the middle one holding the words.
            Text(text.isEmpty ? "Listening…" : text)
                .font(.title3)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .modifier(Slab(
                    shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    isLit: false
                ))
            bar("Cancel", symbol: "trash.fill", colour: .red, isLit: armed == .cancel)
        }
        .frame(width: MacOverlayStyle.maximumWidth, alignment: .leading)
    }

    /// Unlit, a bar is the same slab as an unpicked key; lit, it is the solid
    /// colour the phone's bar turns.
    private func bar(_ title: String, symbol: String, colour: Color, isLit: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Image(systemName: symbol)
        }
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(isLit ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background {
            if isLit {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colour)
            } else {
                Color.clear.modifier(Slab(
                    shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    isLit: false
                ))
            }
        }
    }
}
#endif
