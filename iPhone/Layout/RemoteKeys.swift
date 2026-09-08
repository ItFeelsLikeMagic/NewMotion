#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The size every layout draws a key at.
enum RemoteKeyMetrics {
    static let keyWidth: Double = 56
    static let keyHeight: Double = 64
    static let spacing: Double = 8
    static let clusterWidth = keyWidth * 2 + spacing
    static let clusterHeight = keyHeight * 2 + spacing
    /// Spelled out rather than left to `.padding()` so a layout can cancel
    /// exactly this much and let the trackpad reach the side of the screen.
    static let contentPadding: Double = 16
}

/// The keys a layout can place.  They are the same allowlisted atomic actions
/// the protocol already carries; no key script is possible.  Every key fills
/// the space it is handed, so the layout owns the sizes and this owns what a
/// key does.
@MainActor
struct RemoteKeys {
    let send: (RemoteHotkey) -> Void
    let walk: (TabWalkPhase, HeldModifier) -> Void
    let scrub: (DeleteScrubPhase, DeleteScrubGranularity) -> Void

    var appSwitcher: some View { walkKey("⌘⇥", .command, "App switcher. Hold and slide to choose.") }

    /// Hold and drag to pick up text.
    var select: some View { TextSelectionKey(send: send) }

    var nextTab: some View { walkKey("⌃⇥", .control, "Next tab. Hold and slide to walk.") }

    var escape: some View { titledKey(.escape) }

    var copy: some View { key(.copy) { Image(systemName: "doc.on.doc") } }

    var paste: some View { key(.paste) { Image(systemName: "doc.on.clipboard") } }

    var returnKey: some View { key(.return) { Image(systemName: "return") } }

    /// Tap to rub out, hold and slide across to run, slide up for whole words.
    var delete: some View { DeleteScrubKey(send: send, scrub: scrub) }

    /// A key that says what it sends.
    private func titledKey(_ hotkey: RemoteHotkey) -> some View {
        key(hotkey) { Text(hotkey.buttonTitle) }
    }

    private func walkKey(_ title: String, _ modifier: HeldModifier, _ spokenName: String) -> some View {
        TabWalkButton(
            title: title,
            modifier: modifier,
            spokenName: spokenName,
            send: walk
        )
    }

    /// Drawn like the hold-and-slide keys rather than with `.bordered`, whose
    /// padding leaves a small cell too little room for a two-glyph label.
    private func key<Label: View>(_ hotkey: RemoteHotkey, @ViewBuilder label: () -> Label) -> some View {
        Button(action: Haptics.tap { send(hotkey) }) {
            label()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .background(Color(.secondarySystemFill))
        .foregroundStyle(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(hotkey.spokenName)
    }
}
#endif
