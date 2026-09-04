#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// The upright layout: trackpad on top, keys under both thumbs.  Each cluster
/// keeps its frequent keys in the column nearest the hold bar, so the same
/// reach finds the same kind of key whichever hand holds the phone.
struct VerticalRemoteLayout<Trackpad: View, Controls: View>: View {
    @ObservedObject var pushToTalk: PushToTalkController
    let keys: RemoteKeys
    @ViewBuilder let trackpad: Trackpad
    @ViewBuilder let controls: Controls

    var body: some View {
        VStack(spacing: 12) {
            trackpad
                .overlay { controls }
                // The scroll strips are the thing a thumb reaches for without
                // looking, so they run to the side of the screen rather than
                // stopping short of it and leaving a dead margin.
                .padding(.horizontal, -RemoteKeyMetrics.contentPadding)

            VStack(spacing: RemoteKeyMetrics.spacing) {
                chordRow
                thumbClusters
            }
        }
        .padding(RemoteKeyMetrics.contentPadding)
    }

    /// Whole-window and whole-tab keys.  They are reached for far less often
    /// than the thumb keys, so they take the row a thumb has to stretch for and
    /// leave the corners to return and delete.  The three that are held and
    /// dragged sit in the middle, where a thumb lands squarely enough to drag
    /// from.
    private var chordRow: some View {
        HStack(spacing: RemoteKeyMetrics.spacing) {
            chordSlot { keys.newItem }
            chordSlot { keys.selectAll }
            chordSlot { keys.appSwitcher }
            chordSlot { keys.select }
            chordSlot { keys.nextTab }
            chordSlot { keys.newTab }
            chordSlot { keys.closeWindow }
        }
    }

    /// One stretched cell of the chord row.  The row is wider than it is tall,
    /// so its keys take the width they are given rather than a fixed one.
    private func chordSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: RemoteKeyMetrics.keyHeight)
    }

    private var thumbClusters: some View {
        HStack(alignment: .top, spacing: RemoteKeyMetrics.spacing) {
            cluster {
                slot { keys.escape }
                slot { keys.nextWindow }
            } bottom: {
                slot { keys.copy }
                slot { keys.paste }
            }

            PushToTalkButton(controller: pushToTalk)
                .frame(maxWidth: .infinity)

            // Return takes the inner top corner: it is the key that follows a
            // dictated line, so it sits right against the hold bar.  The three
            // deletes fill the rest, growing outward from the character.
            cluster {
                slot { keys.returnKey }
                slot { keys.deleteLine }
            } bottom: {
                slot { keys.deleteCharacter }
                slot { keys.deleteWord }
            }
        }
    }

    private func cluster<Top: View, Bottom: View>(
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        VStack(spacing: RemoteKeyMetrics.spacing) {
            HStack(spacing: RemoteKeyMetrics.spacing) { top() }
            HStack(spacing: RemoteKeyMetrics.spacing) { bottom() }
        }
        .frame(width: RemoteKeyMetrics.clusterWidth)
    }

    /// One fixed cell.  Every key fills the width it is offered, so the layout
    /// sets the size once here rather than each key guessing.
    private func slot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: RemoteKeyMetrics.keyWidth, height: RemoteKeyMetrics.keyHeight)
    }
}
#endif
