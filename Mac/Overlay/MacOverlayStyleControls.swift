#if os(macOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// A card held up while the look is being tuned. Copy, Up and Word are
/// stand-ins for a lit key of each kind; what is being looked at is the style,
/// not them.
enum MacOverlayPreview: String, CaseIterable, Identifiable {
    case off
    case command
    case arrows
    case backspace
    case dictation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .command: return "Command"
        case .arrows: return "Arrows"
        case .backspace: return "Backspace"
        case .dictation: return "Dictation"
        }
    }

    var content: MacOverlayContent? {
        switch self {
        case .off: return nil
        case .command: return .picker(cell: .copy)
        case .arrows: return .arrows(lit: .arrowUp)
        case .backspace: return .delete(granularity: .word)
        // Words of the stand-in's own, never anyone's, and the Send bar armed
        // so the whole card is on screen while it is being tuned.
        case .dictation: return .transcript("the quick brown fox", armed: .send)
        }
    }
}

/// The tuning panel in the menu bar popover. Collapsed until someone opens it,
/// because it is a great deal of chrome for something touched once.
struct MacOverlayStyleSection: View {
    @ObservedObject var styles: MacOverlayStyleStore
    @Binding var preview: MacOverlayPreview

    @AppStorage("overlayStyleExpanded") private var isExpanded = false

    var body: some View {
        DisclosureGroup("Card style", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                // First, because nothing below it can be judged without a card
                // on screen to judge it on.
                Picker("Preview", selection: $preview) {
                    ForEach(MacOverlayPreview.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                header("Glass")
                Picker("Glass", selection: $styles.style.glass) {
                    ForEach(MacOverlayStyle.GlassKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Tint the lit key", isOn: $styles.style.tintsLitKey)
                slider("Glass opacity", $styles.style.glassOpacity,
                       in: MacOverlayStyle.glassOpacityRange, step: 0.05, decimals: 2)
                slider("Backing", $styles.style.backing,
                       in: MacOverlayStyle.backingRange, step: 0.05, decimals: 2)

                header("Keys")
                slider("Tile size", $styles.style.tileSide,
                       in: MacOverlayStyle.tileSideRange, step: 1, decimals: 0)
                slider("Corner", $styles.style.tileCorner,
                       in: MacOverlayStyle.tileCornerRange, step: 1, decimals: 0)
                slider("Gap", $styles.style.tileSpacing,
                       in: MacOverlayStyle.tileSpacingRange, step: 1, decimals: 0)

                header("Text")
                slider("Key size", $styles.style.capFontSize,
                       in: MacOverlayStyle.capFontSizeRange, step: 1, decimals: 0)
                Toggle("Bold keys", isOn: $styles.style.boldCaps)
                Toggle("Shadow behind text", isOn: $styles.style.textShadow)
                Toggle("Show key names", isOn: $styles.style.showsNames)
                slider("Name size", $styles.style.nameFontSize,
                       in: MacOverlayStyle.nameFontSizeRange, step: 0.5, decimals: 1)
                    .disabled(!styles.style.showsNames)

                header("Layout")
                slider("Row stagger", $styles.style.stagger,
                       in: MacOverlayStyle.staggerRange, step: 0.05, decimals: 2)
                slider("Fade", $styles.style.fadeDuration,
                       in: MacOverlayStyle.fadeDurationRange, step: 0.01, decimals: 2)
                Toggle("Caption on the delete card", isOn: $styles.style.captionOnDeleteCard)

                Button("Reset to defaults") { styles.style = .standard }
                    .disabled(styles.style == .standard)
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func slider(
        _ title: String,
        _ value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        decimals: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                Spacer(minLength: 4)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(decimals)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
#endif
