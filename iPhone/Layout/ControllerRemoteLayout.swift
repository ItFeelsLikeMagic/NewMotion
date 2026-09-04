#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// The sideways layout: every key under one thumb, the whole trackpad under
/// the other.  Mirrored, the two swap sides for a left-handed hold.
struct ControllerRemoteLayout<Trackpad: View>: View {
    /// Enough width for four keys and their gaps; the trackpad takes the rest.
    private static var keyColumnShare: Double { 0.42 }

    @ObservedObject var pushToTalk: PushToTalkController
    let keys: RemoteKeys
    let mirrored: Bool
    @ViewBuilder let trackpad: Trackpad

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: RemoteKeyMetrics.spacing) {
                if mirrored {
                    // Only the outer edge is cancelled, so the trackpad reaches
                    // the side of the screen without running under the keys.
                    trackpad.padding(.leading, -RemoteKeyMetrics.contentPadding)
                    keyColumn(width: proxy.size.width)
                } else {
                    keyColumn(width: proxy.size.width)
                    trackpad.padding(.trailing, -RemoteKeyMetrics.contentPadding)
                }
            }
        }
        .padding(RemoteKeyMetrics.contentPadding)
    }

    private func keyColumn(width: Double) -> some View {
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
        .frame(width: width * Self.keyColumnShare)
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
