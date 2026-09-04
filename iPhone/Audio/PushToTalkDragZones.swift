#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// A target the finger can be dragged to while holding to talk.  Cancel throws
/// the utterance away; edit turns it into an instruction for the words already
/// in the field.  Each kind has one on either side so the thumb only ever
/// travels to the near one.
public enum PushToTalkZone: CaseIterable, Sendable {
    case cancelLeading
    case cancelTrailing
    case editLeading
    case editTrailing

    public var isEdit: Bool { self == .editLeading || self == .editTrailing }
    var isLeading: Bool { self == .cancelLeading || self == .editLeading }
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

/// The drag targets, visible only while a hold is in progress.  The cancel
/// circles are centred on the bottom corners, so a quarter of each shows; the
/// edit circles are centred on the side edges above them, showing a half.  They
/// never take the touch: the hold owns it from press to release, so the
/// controller hit-tests the finger against the frames these report.
struct PushToTalkDragZones: View {
    private static let cancelDiameter: Double = 240
    private static let editDiameter: Double = 140
    /// Clear of the cancel circle, which reaches this far up the side edge.
    private static let editBottomInset: Double = 150

    @ObservedObject var controller: PushToTalkController
    let sides: PushToTalkZoneSides

    var body: some View {
        ZStack {
            ForEach(shownZones, id: \.self) { zone($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .opacity(controller.isHolding ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: controller.isHolding)
        .animation(.easeOut(duration: 0.12), value: controller.armedZone)
    }

    private var shownZones: [PushToTalkZone] {
        PushToTalkZone.allCases.filter { sides.includes($0) && (!$0.isEdit || controller.editEnabled) }
    }

    private func zone(_ zone: PushToTalkZone) -> some View {
        let armed = controller.armedZone == zone
        let tint = zone.isEdit ? Color.accentColor : Color.red
        let diameter = zone.isEdit ? Self.editDiameter : Self.cancelDiameter
        // Into the visible slice: diagonally for a corner, sideways for an edge.
        let labelInset = diameter / 4
        return ZStack {
            // Glass while it waits, solid the moment the finger is on it, so
            // the armed target is unmistakable.
            if armed {
                Circle().fill(tint)
            } else {
                FrostedDisc(tint: tint)
            }
            VStack(spacing: 4) {
                Image(systemName: icon(for: zone, armed: armed))
                    .font(zone.isEdit ? .body : .title2)
                Text(armed ? "Release" : (zone.isEdit ? "Edit" : "Cancel"))
                    .font(.caption2)
            }
            .foregroundStyle(armed ? Color.white : tint)
            .offset(
                x: zone.isLeading ? labelInset : -labelInset,
                y: zone.isEdit ? 0 : -labelInset
            )
        }
        .frame(width: diameter, height: diameter)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            controller.setZoneFrame(zone, frame)
        }
        // A target that has left the screen must stop catching the finger.
        .onDisappear { controller.setZoneFrame(zone, .zero) }
        // Negative padding rather than an offset: it moves the circle in
        // layout, so the frame it reports is where the finger will find it.
        .padding(zone.isLeading ? .leading : .trailing, -diameter / 2)
        .padding(.bottom, zone.isEdit ? Self.editBottomInset : -diameter / 2)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: zone.isLeading ? .bottomLeading : .bottomTrailing
        )
    }

    private func icon(for zone: PushToTalkZone, armed: Bool) -> String {
        if zone.isEdit { return armed ? "pencil.circle.fill" : "pencil" }
        return armed ? "trash.fill" : "trash"
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
