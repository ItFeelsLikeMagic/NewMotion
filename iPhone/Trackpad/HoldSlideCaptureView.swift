#if canImport(UIKit)
import UIKit

/// What a press on a hold-and-slide control is doing right now.  Translation
/// is horizontal only; the control decides what a distance means.
public enum HoldSlidePhase: Equatable, Sendable {
    case began
    case moved(translationX: Double)
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
        let translation = trackedTouch.location(in: self).x - origin.x
        onPhase?(.moved(translationX: Double(translation)))
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
    /// is never left holding Command.
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
#endif
