#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// The size every layout draws a key at.
enum RemoteKeyMetrics {
    static let keyWidth: Double = 48
    static let keyHeight: Double = 46
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
    let walkSensitivity: Double
    let walk: (TabWalkPhase, HeldModifier) -> Void
    let scrubEnabled: Bool
    let scrub: (DeleteScrubPhase, DeleteScrubGranularity) -> Void

    /// Whole-window and whole-tab keys.  They are reached for far less often
    /// than the thumb keys, so they take the row a thumb has to stretch for and
    /// leave the corners to return and delete.  The three that are held and
    /// dragged sit in the middle, where a thumb lands squarely enough to drag
    /// from.
    var chordRow: some View {
        HStack(spacing: RemoteKeyMetrics.spacing) {
            chordSlot { titledKey(.newItem) }
            chordSlot { titledKey(.selectAll) }
            chordSlot { walkKey("⌘⇥", .command, "App switcher. Hold and slide to choose.") }
            chordSlot { TextSelectionKey(send: send) }
            chordSlot { walkKey("⌃⇥", .control, "Next tab. Hold and slide to walk.") }
            chordSlot { titledKey(.newTab) }
            chordSlot { titledKey(.closeWindow) }
        }
    }

    var escape: some View { titledKey(.escape) }

    var nextWindow: some View { titledKey(.nextWindow) }

    var copy: some View { key(.copy) { Image(systemName: "doc.on.doc") } }

    var paste: some View { key(.paste) { Image(systemName: "doc.on.clipboard") } }

    var returnKey: some View { key(.return) { Image(systemName: "return") } }

    var deleteLine: some View { titledKey(.deleteLineBackward) }

    var deleteCharacter: some View {
        deleteKey(.deleteBackward, .character) { Image(systemName: "delete.left") }
    }

    var deleteWord: some View {
        deleteKey(.deleteWordBackward, .word) { Text(RemoteHotkey.deleteWordBackward.buttonTitle) }
    }

    /// A key that says what it sends.
    private func titledKey(_ hotkey: RemoteHotkey) -> some View {
        key(hotkey) { Text(hotkey.buttonTitle) }
    }

    /// One stretched cell of the chord row.  The row is wider than it is tall,
    /// so its keys take the width they are given rather than a fixed one.
    private func chordSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: RemoteKeyMetrics.keyHeight)
    }

    private func walkKey(_ title: String, _ modifier: HeldModifier, _ spokenName: String) -> some View {
        TabWalkButton(
            title: title,
            modifier: modifier,
            spokenName: spokenName,
            sensitivity: walkSensitivity,
            send: walk
        )
    }

    /// Drawn like the hold-and-slide keys rather than with `.bordered`, whose
    /// padding leaves a 48pt cell too little room for a two-glyph label.
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

    /// With the slide off, a delete key is an ordinary key and nothing about it
    /// changes.
    @ViewBuilder
    private func deleteKey<Label: View>(
        _ hotkey: RemoteHotkey,
        _ granularity: DeleteScrubGranularity,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if scrubEnabled {
            DeleteScrubKey(
                hotkey: hotkey,
                granularity: granularity,
                send: send,
                scrub: scrub,
                label: label()
            )
        } else {
            key(hotkey, label: label)
        }
    }
}
#endif
