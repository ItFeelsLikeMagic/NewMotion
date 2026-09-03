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

    var body: some View {
        ZStack {
            zone(.cancelLeading)
            zone(.cancelTrailing)
            if controller.editEnabled {
                zone(.editLeading)
                zone(.editTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .opacity(controller.isHolding ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: controller.isHolding)
        .animation(.easeOut(duration: 0.12), value: controller.armedZone)
    }

    private func zone(_ zone: PushToTalkZone) -> some View {
        let armed = controller.armedZone == zone
        let tint = zone.isEdit ? Color.accentColor : Color.red
        let diameter = zone.isEdit ? Self.editDiameter : Self.cancelDiameter
        // Into the visible slice: diagonally for a corner, sideways for an edge.
        let labelInset = diameter / 4
        return Circle()
            .fill(armed ? tint : tint.opacity(0.16))
            .overlay {
                Circle().strokeBorder(tint.opacity(armed ? 0 : 0.55), lineWidth: 1)
            }
            .overlay {
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
#endif
