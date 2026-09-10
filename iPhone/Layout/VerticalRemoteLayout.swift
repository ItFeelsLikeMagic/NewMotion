#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// The upright layout: trackpad on top, keys under both thumbs.  Every key a
/// thumb taps is in one of the two clusters, so nothing needs a stretch past
/// the row a thumb rests on, and each cluster keeps its frequent keys in the
/// column nearest the hold bar.
struct VerticalRemoteLayout<Trackpad: View, Controls: View>: View {
    @ObservedObject var pushToTalk: PushToTalkController
    let keys: RemoteKeys
    @ViewBuilder let trackpad: Trackpad
    @ViewBuilder let controls: Controls

    var body: some View {
        // The pad is pulled out to the glass by hand rather than by ignoring
        // the safe area: inside a padded stack that modifier leaves it where
        // it was, and the inset has to be cancelled to reach the top anyway.
        GeometryReader { proxy in
            VStack(spacing: 12) {
                // Only the pad goes out to the edges.  The controls floating on
                // it stay in the safe area, clear of the notch, and stay
                // against the bottom of the pad when a keyboard shortens it.
                ZStack {
                    trackpad
                        .padding(.horizontal, -RemoteKeyMetrics.contentPadding)
                        .padding(.top, -(RemoteKeyMetrics.contentPadding + proxy.safeAreaInsets.top))
                    controls
                        .clearOfKeyboard()
                }

                // Send goes above the microphone, where the clusters cannot
                // make room for it, so the pad gives up the height instead:
                // it is the only thing here that stretches, so it shrinks by
                // exactly what the bar takes and nothing below it moves.
                // Cancel gets a row of its own below, which exists only while
                // a hold is on.
                if pushToTalk.isHolding {
                    chordBar(.send)
                }

                thumbRow

                if pushToTalk.isHolding {
                    chordBar(.cancel)
                }
            }
            .padding(RemoteKeyMetrics.contentPadding)
        }
    }

    /// A key's height, the whole width the keys had: the bar is a target for a
    /// thumb already sliding, not something anyone aims at.
    private func chordBar(_ zone: PushToTalkZone) -> some View {
        PushToTalkZoneBar(controller: pushToTalk, zone: zone)
            .frame(height: RemoteKeyMetrics.keyHeight)
    }

    /// The inner column of each cluster is the one a thumb finds first, so
    /// return and delete sit against the hold bar on the right and copy and
    /// paste on the left.  The three keys that are held and dragged take the
    /// outer half, where a thumb has room to travel without leaving the phone,
    /// the picker among them: it slides across a whole grid, so it wants that
    /// room more than any of them, and it sits above the walk key so the two
    /// slides share one corner of the pad.
    /// A hold clears both clusters out of the row and the microphone spreads
    /// across it, keeping the height it had so the thumb's target holds still.
    private var thumbRow: some View {
        HStack(alignment: .top, spacing: RemoteKeyMetrics.spacing) {
            if !pushToTalk.isHolding {
                cluster {
                    slot { keys.commandPicker }
                    slot { keys.copy }
                } bottom: {
                    slot { keys.tabWalk }
                    slot { keys.paste }
                }
            }

            PushToTalkButton(controller: pushToTalk, micHeight: RemoteKeyMetrics.clusterHeight)
                .frame(maxWidth: .infinity)

            if !pushToTalk.isHolding {
                cluster {
                    slot { keys.returnKey }
                    slot { keys.escape }
                } bottom: {
                    slot { keys.delete }
                    slot { keys.select }
                }
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
