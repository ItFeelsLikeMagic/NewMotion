#if os(macOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The card itself: one thing at a time, sized to what it says, centred in a
/// pane of one fixed size.
struct MacOverlayView: View {
    /// The pane the card floats in. Fixed, and comfortably bigger than the
    /// widest thing the card can say, so the panel never has to be measured or
    /// resized: measuring it meant reading a view that was still animating, and
    /// the first card of a session came up the size of an empty one. Everything
    /// around the card is clear and click-through, so the spare room costs
    /// nothing.
    static let panelSize = CGSize(width: 560, height: 220)
    /// Long enough for a line of dictation without reaching across a display.
    private static let maximumWidth: CGFloat = 460
    private static let fade: Animation = .easeInOut(duration: 0.12)

    @ObservedObject var shown: MacOverlayContentBox

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .fixedSize()
            .animation(Self.fade, value: shown.content)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
    }

    @ViewBuilder
    private var content: some View {
        switch shown.content {
        case .nothing:
            EmptyView()
        case let .picker(cell):
            grid(lit: cell)
        case let .transcript(text):
            transcript(text)
        case let .hint(text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func grid(lit: HotkeyAction?) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(KeyPickerGrid.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { cell in
                        Text(KeyPickerGrid.displayName(for: cell) ?? "")
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(cell == lit ? Color.white : Color.primary)
                            .background(
                                Capsule().fill(cell == lit ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                    }
                }
            }
        }
    }

    /// Truncated at the head, so the newest words are the ones still on
    /// screen: this is a glance at the tail of a sentence, not a transcript.
    /// The width is fixed rather than fitted, so the card does not shuffle
    /// sideways on every partial.
    private func transcript(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(width: Self.maximumWidth, alignment: .leading)
    }
}
#endif
