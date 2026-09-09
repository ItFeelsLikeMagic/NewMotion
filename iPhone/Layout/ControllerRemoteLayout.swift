#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// The sideways layout: every key under one thumb, the whole trackpad under
/// the other.  Mirrored, the two swap sides for a left-handed hold.
struct ControllerRemoteLayout<Trackpad: View, Controls: View>: View {
    /// Enough width for the top row's five keys and their gaps; the trackpad
    /// takes the rest.
    private static var keyColumnShare: Double { 0.42 }

    @ObservedObject var pushToTalk: PushToTalkController
    let keys: RemoteKeys
    let mirrored: Bool
    @ViewBuilder let trackpad: Trackpad
    @ViewBuilder let controls: Controls

    var body: some View {
        // Nothing pads the whole screen: a padded ancestor would sit inside
        // the safe area and stop passing it down, and the trackpad needs it
        // to know how far past the content edge the glass goes.
        // The keyboard does not resize this layout.  Sideways there is no room
        // to shrink into: the pad would lose a third of its height and the keys
        // would still end up under the keyboard, so the keyboard covers the
        // bottom of both and the controls floating on the pad step over it.
        GeometryReader { proxy in
            HStack(spacing: RemoteKeyMetrics.spacing) {
                if mirrored {
                    edgeToEdgeTrackpad(outerEdge: .leading)
                    keyColumn(width: proxy.size.width, screenEdge: .trailing)
                } else {
                    keyColumn(width: proxy.size.width, screenEdge: .leading)
                    edgeToEdgeTrackpad(outerEdge: .trailing)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    /// The trackpad runs to the physical edge on every side but the keys',
    /// under the safe area included, while the controls floating on it stay in
    /// the safe area of the same cell.  Only the pad ignores it: padding the
    /// controls back by hand would count a raised keyboard twice, once in the
    /// shrunken layout and again in the inset, and lift them off the pad.
    private func edgeToEdgeTrackpad(outerEdge: Edge) -> some View {
        let outer = Edge.Set(outerEdge)
        return ZStack {
            trackpad
                .ignoresSafeArea(.container, edges: outer.union(.vertical))
            controls
                .clearOfKeyboard()
        }
    }

    /// Keeps the content margin on its screen side and above and below, the
    /// margins the whole screen used to carry.
    private func keyColumn(width: Double, screenEdge: Edge) -> some View {
        VStack(spacing: RemoteKeyMetrics.spacing) {
            // The app switcher, held and dragged, sits beside the hold bar so
            // a drag starts from where the thumb already rests, with escape
            // next to it as the way out of whatever that drag opened.  The
            // picker slides across a whole grid, so it takes the far end,
            // where a slide has the most room before it leaves the phone.
            HStack(spacing: RemoteKeyMetrics.spacing) {
                slot { keys.commandPicker }
                slot { keys.copy }
                slot { keys.paste }
                slot { keys.appSwitcher }
                slot { keys.escape }
            }

            // The hold bar is the point of the whole column, so it takes every
            // point the keys leave and sits where the thumb already rests.
            PushToTalkButton(controller: pushToTalk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: RemoteKeyMetrics.spacing) {
                slot { keys.nextTab }
                slot { keys.select }
                slot { keys.returnKey }
                slot { keys.delete }
            }
        }
        .frame(width: (width - 2 * RemoteKeyMetrics.contentPadding) * Self.keyColumnShare)
        .padding(.vertical, RemoteKeyMetrics.contentPadding)
        .padding(Edge.Set(screenEdge), RemoteKeyMetrics.contentPadding)
    }

    /// One stretched cell.  The column takes a share of the screen rather than
    /// a fixed width, so keys take the width they are given.
    private func slot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: RemoteKeyMetrics.keyHeight)
    }
}
#endif
