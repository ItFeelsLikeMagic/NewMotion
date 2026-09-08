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
            .animation(Self.fade, value: shape)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
    }

    /// What the fade is allowed to notice.  A card arriving or leaving, and a
    /// picker lighting a different key, are worth a fade; a transcript revising
    /// its words ten times a second is not, and animating those smears them.
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

    /// The same capsules as the picker, because it is the same gesture: hold a
    /// key and slide. Two of them, and a line saying what across does, since
    /// the card is up before the finger has moved and that is the moment the
    /// reminder is worth anything.
    private func deleteUnits(lit: DeleteScrubGranularity) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(DeleteScrubGranularity.allCases, id: \.self) { unit in
                    Text(Self.unitName(unit))
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(unit == lit ? Color.white : Color.primary)
                        .background(
                            Capsule().fill(unit == lit ? Color.accentColor : Color.primary.opacity(0.08))
                        )
                }
            }
            Text("Slide left to erase, right to restore")
                .font(.caption)
                .foregroundStyle(.secondary)
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
