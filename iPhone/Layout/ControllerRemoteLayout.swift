#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// The sideways layout: every key under one thumb, the whole trackpad under
/// the other.  Mirrored, the two swap sides for a left-handed hold.
struct ControllerRemoteLayout<Trackpad: View, Controls: View>: View {
    /// Enough width for four keys and their gaps; the trackpad takes the rest.
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
        GeometryReader { proxy in
            HStack(spacing: RemoteKeyMetrics.spacing) {
                if mirrored {
                    edgeToEdgeTrackpad(outerEdge: .leading, safeArea: proxy.safeAreaInsets)
                    keyColumn(width: proxy.size.width, screenEdge: .trailing)
                } else {
                    keyColumn(width: proxy.size.width, screenEdge: .leading)
                    edgeToEdgeTrackpad(outerEdge: .trailing, safeArea: proxy.safeAreaInsets)
                }
            }
        }
    }

    /// The trackpad runs to the physical edge on every side but the keys',
    /// under the safe area included; the controls floating on it are padded
    /// back inside the safe area so nothing sits under the notch or the home
    /// indicator.
    private func edgeToEdgeTrackpad(outerEdge: Edge, safeArea: EdgeInsets) -> some View {
        let outer = Edge.Set(outerEdge)
        return trackpad
            .overlay {
                controls
                    .padding(outer, outerEdge == .leading ? safeArea.leading : safeArea.trailing)
                    .padding(.top, safeArea.top)
                    .padding(.bottom, safeArea.bottom)
            }
            .ignoresSafeArea(.container, edges: outer.union(.vertical))
    }

    /// Keeps the content margin on its screen side and above and below, the
    /// margins the whole screen used to carry.
    private func keyColumn(width: Double, screenEdge: Edge) -> some View {
        VStack(spacing: RemoteKeyMetrics.spacing) {
            HStack(spacing: RemoteKeyMetrics.spacing) {
                slot { keys.newItem }
                slot { keys.selectAll }
                slot { keys.nextWindow }
                slot { keys.deleteLine }
                slot { keys.nextTab }
                slot { keys.newTab }
                slot { keys.closeWindow }
            }
            // The two drag keys sit beside the hold bar: sideways, that is the
            // row the thumb rests on, so a drag starts from where it already is.
            HStack(spacing: RemoteKeyMetrics.spacing) {
                slot { keys.escape }
                slot { keys.appSwitcher }
                slot { keys.returnKey }
                slot { keys.select }
            }

            // The hold bar is the point of the whole column, so it takes every
            // point the keys leave and sits where the thumb already rests.
            PushToTalkButton(controller: pushToTalk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: RemoteKeyMetrics.spacing) {
                slot { keys.copy }
                slot { keys.paste }
                slot { keys.deleteCharacter }
                slot { keys.deleteWord }
            }
        }
        .frame(width: (width - 2 * RemoteKeyMetrics.contentPadding) * Self.keyColumnShare)
        .padding(.vertical, RemoteKeyMetrics.contentPadding)
        .padding(Edge.Set(screenEdge), RemoteKeyMetrics.contentPadding)
    }

    /// One stretched cell.  The column is narrow and its rows differ in count,
    /// so keys take the width they are given rather than a fixed one.
    private func slot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: RemoteKeyMetrics.keyHeight)
    }
}
#endif
