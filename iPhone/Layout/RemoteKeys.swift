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
    let walk: (TabWalkPayload) -> Void
    let scrub: (DeleteScrubPhase, DeleteScrubGranularity) -> Void
    let picker: (KeyPickerPhase, HotkeyAction?) -> Void

    /// Hold to open the app switcher and slide across to choose; slide up and
    /// the same press walks the front app's tabs, down and it walks its
    /// windows.
    var tabWalk: some View { TabWalkKey(walk: walk) }

    /// Hold and drag to pick up text.
    var select: some View { TextSelectionKey(send: send) }

    /// Hold and slide to choose a Command shortcut off the grid the Mac draws.
    /// Its cells are the shared allowlist, so this key adds no new action.
    var commandPicker: some View { CommandPickerKey(picker: picker) }

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

    /// Wears the same face as the hold-and-slide keys, and wears it plainly:
    /// the system's own button styling puts its shape and its padding on top
    /// of whatever it is given, which is what made these keys read as a
    /// different set from the held ones.
    private func key<Label: View>(_ hotkey: RemoteHotkey, @ViewBuilder label: () -> Label) -> some View {
        Button(action: Haptics.tap { send(hotkey) }) {
            label().keyFace()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hotkey.spokenName)
    }
}
#endif
