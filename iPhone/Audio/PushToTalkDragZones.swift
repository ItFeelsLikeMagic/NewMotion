#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// A target the finger can be dragged to while holding to talk.  Releasing
/// over one throws the utterance away.  There is one on either side so the
/// thumb only ever travels to the near one.
public enum PushToTalkZone: CaseIterable, Sendable {
    case cancelLeading
    case cancelTrailing

    var isLeading: Bool { self == .cancelLeading }
}

/// Which sides of the screen carry drag targets.  Upright, the hold bar is in
/// the middle and either thumb may be on it, so both sides do; sideways, only
/// the side the hold bar is on, so the thumb never has to cross the trackpad.
enum PushToTalkZoneSides: Sendable {
    case both
    case leading
    case trailing

    func includes(_ zone: PushToTalkZone) -> Bool {
        switch self {
        case .both: return true
        case .leading: return zone.isLeading
        case .trailing: return !zone.isLeading
        }
    }
}

/// The cancel targets, visible only while a hold is in progress.  They are
/// centred on the bottom corners, so a quarter of each shows.  They never take
/// the touch: the hold owns it from press to release, so the controller
/// hit-tests the finger against the frames these report.
struct PushToTalkDragZones: View {
    private static let diameter: Double = 240

    @ObservedObject var controller: PushToTalkController
    let sides: PushToTalkZoneSides

    var body: some View {
        ZStack {
            ForEach(PushToTalkZone.allCases.filter(sides.includes), id: \.self) { zone($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .opacity(controller.isHolding ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: controller.isHolding)
        .animation(.easeOut(duration: 0.12), value: controller.armedZone)
    }

    private func zone(_ zone: PushToTalkZone) -> some View {
        let armed = controller.armedZone == zone
        // Diagonally into the visible slice of the corner.
        let labelInset = Self.diameter / 4
        return ZStack {
            // Glass while it waits, solid the moment the finger is on it, so
            // the armed target is unmistakable.
            if armed {
                Circle().fill(Color.red)
            } else {
                FrostedDisc(tint: .red)
            }
            VStack(spacing: 4) {
                Image(systemName: armed ? "trash.fill" : "trash")
                    .font(.title2)
                Text(armed ? "Release" : "Cancel")
                    .font(.caption2)
            }
            .foregroundStyle(armed ? Color.white : Color.red)
            .offset(x: zone.isLeading ? labelInset : -labelInset, y: -labelInset)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            controller.setZoneFrame(zone, frame)
        }
        // A target that has left the screen must stop catching the finger.
        .onDisappear { controller.setZoneFrame(zone, .zero) }
        // Negative padding rather than an offset: it moves the circle in
        // layout, so the frame it reports is where the finger will find it.
        .padding(zone.isLeading ? .leading : .trailing, -Self.diameter / 2)
        .padding(.bottom, -Self.diameter / 2)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: zone.isLeading ? .bottomLeading : .bottomTrailing
        )
    }
}

/// Glass over the screen with a wash of the zone's colour.  Under the corners
/// there is only the window background and the pale key fills, which no blur
/// can make show through; the glass rim is what says the disc sits on top.
private struct FrostedDisc: View {
    let tint: Color

    var body: some View {
        if #available(iOS 26, *) {
            Color.clear.glassEffect(.regular.tint(tint.opacity(0.2)), in: .circle)
        } else {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(tint.opacity(0.16))
            Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1)
        }
    }
}
#endif
