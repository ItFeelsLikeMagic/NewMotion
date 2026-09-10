#if canImport(UIKit)
import SwiftUI
import UIKit

/// What a press on a hold-and-slide control is doing right now.  Translation
/// is measured from where the finger landed; the control decides what a
/// distance means and which axes it reads.
public enum HoldSlidePhase: Equatable, Sendable {
    case began
    case moved(translationX: Double, translationY: Double)
    case ended
    case cancelled
}

/// Touch capture for a press-and-hold control.  SwiftUI's `DragGesture` took
/// between 100 and 780 ms to hand over a touch that UIKit already had, which is
/// why the trackpad has always felt immediate and buttons built on the gesture
/// did not.  Like `TrackpadTouchCaptureView`, this only supplies touches; the
/// control above it owns what they mean.
public final class HoldSlideCaptureView: UIView {
    public var onPhase: ((HoldSlidePhase) -> Void)?
    /// Names this control in the debug log's touch-delivery timing.
    public var label = "hold_slide"

    private var trackedTouch: UITouch?
    private var origin: CGPoint?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        origin = touch.location(in: self)
        IPhoneDebugLog.emit("touch_lag", [
            "control": label,
            "ms": String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - touch.timestamp) * 1_000)
        ])
        onPhase?(.began)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch), let origin else { return }
        let location = trackedTouch.location(in: self)
        onPhase?(.moved(
            translationX: Double(location.x - origin.x),
            translationY: Double(location.y - origin.y)
        ))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        finish(.ended)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        finish(.cancelled)
    }

    /// Leaving the window ends the press the same way a cancel does, so the Mac
    /// is never left holding a modifier.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, trackedTouch != nil { finish(.cancelled) }
    }

    private func configure() {
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = true
        backgroundColor = .clear
        // The SwiftUI label above this view is the accessible element.
        isAccessibilityElement = false
    }

    private func finish(_ phase: HoldSlidePhase) {
        trackedTouch = nil
        origin = nil
        onPhase?(phase)
    }
}

/// Lays the capture view over a SwiftUI control.  Every hold-and-slide control
/// takes its touches through this, so none of them are left on `DragGesture`.
struct HoldSlideSurface: UIViewRepresentable {
    let label: String
    let onPhase: (HoldSlidePhase) -> Void

    func makeUIView(context: Context) -> HoldSlideCaptureView {
        let view = HoldSlideCaptureView(frame: .zero)
        view.label = label
        view.onPhase = onPhase
        return view
    }

    func updateUIView(_ view: HoldSlideCaptureView, context: Context) {
        view.onPhase = onPhase
    }
}

/// The shared look of every key on the pad: it fills the cell the layout gives
/// it and lights up while a finger is down.  One face for the tapped keys and
/// the held ones both, because two of them cannot drift into different sizes
/// or different corners.
extension View {
    func keyFace(isHeld: Bool = false) -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isHeld ? Color.accentColor : Color(.secondarySystemFill))
            .foregroundStyle(isHeld ? Color.white : Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }

    /// The shared behaviour of a key that is held and dragged: touches come
    /// from UIKit rather than a SwiftUI gesture, and a system interruption
    /// cancels the press rather than leaving the Mac holding what it started.
    func holdSlide(
        _ debugLabel: String,
        spokenName: String,
        onPhase: @escaping (HoldSlidePhase) -> Void
    ) -> some View {
        modifier(HoldSlideBehavior(debugLabel: debugLabel, spokenName: spokenName, onPhase: onPhase))
    }
}

private struct HoldSlideBehavior: ViewModifier {
    let debugLabel: String
    let spokenName: String
    let onPhase: (HoldSlidePhase) -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay(HoldSlideSurface(label: debugLabel, onPhase: onPhase))
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { onPhase(.cancelled) }
            }
            .accessibilityLabel(spokenName)
    }
}
#endif
