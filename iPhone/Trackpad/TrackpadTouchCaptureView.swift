#if canImport(UIKit)
import UIKit

/// UIKit-only adapter.  Gesture semantics remain in TrackpadGestureEngine and
/// the glide curve in ScrollMomentum; this view only supplies touches, frame
/// timing, and never emits protocol messages itself.
public final class TrackpadTouchCaptureView: UIView {
    public var onOutputs: (([RemoteInputEvent]) -> Void)?
    /// Fires when one finger enters or leaves an edge strip, so the air mouse
    /// can send its travel as scroll for as long as the finger is down.
    public var onOneFingerScrollChanged: ((Bool) -> Void)?
    public var engine = TrackpadGestureEngine()

    private let momentum = ScrollMomentumDriver()
    /// Zero means a flick simply stops when the finger lifts.
    public var momentumStrength: Double {
        get { momentum.strength }
        set { momentum.strength = newValue }
    }

    public static let defaultMomentumStrength = ScrollMomentumDriver.defaultStrength
    /// The touch that stops a glide must not also click, the same way stopping
    /// a scrolling list on iOS does not tap what is under the finger.
    private var suppressClicks = false
    /// Three fingers are the one gesture whose silence is ambiguous: nothing
    /// downstream fires unless the swipe is long enough, so the count itself is
    /// logged to separate a short swipe from touches that never arrived.
    private var peakTouches = 0
    private var oneFingerScrolling = false
    /// A drag whose finger has left holds the button down for a grace window,
    /// and no touch will arrive to close it.  This is that window's clock.
    private var dragReleaseTimer: Timer?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        momentum.stop()
        if window == nil {
            onOutputs?(engine.handle(.cancel))
        } else {
            onOutputs?(engine.handle(.foreground))
        }
        scheduleDragRelease()
        publishOneFingerScroll()
    }

    /// The edge strips are measured from the sides of the glass, so the engine
    /// needs the width every time the layout settles on a new one.
    public override func layoutSubviews() {
        super.layoutSubviews()
        engine.setSurfaceWidth(Double(bounds.width))
    }

    /// Leaving the app while a drag holds the button down would strand it on
    /// the Mac until Bluetooth noticed.  Touches are not always cancelled on
    /// the way out, so the surface is told directly.
    public func setActive(_ isActive: Bool) {
        guard isActive != engine.isForeground else { return }
        onOutputs?(engine.handle(isActive ? .foreground : .background))
        scheduleDragRelease()
        publishOneFingerScroll()
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .began)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .moved)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .ended)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, phase: .cancelled)
    }

    private func configure() {
        momentum.onStep = { [weak self] delta in
            self?.onOutputs?([.scroll(delta)])
        }
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    private func forward(_ touches: Set<UITouch>, phase: TrackpadTouchPhase) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        if phase == .began {
            if momentum.isActive { suppressClicks = true }
            momentum.stop()
        }

        let values = touches.map { touch in
            TrackpadTouch(
                id: UInt64(bitPattern: Int64(touch.hashValue)),
                location: TrackpadPoint(
                    x: Double(touch.location(in: self).x),
                    y: Double(touch.location(in: self).y)
                ),
                phase: phase,
                timestamp: timestamp
            )
        }

        var outputs = engine.handle(values)
        peakTouches = max(peakTouches, engine.activeTouchCount)
        momentum.track(travel: scrollTravel(in: outputs), at: timestamp)

        let gestureEnded = engine.activeTouchCount == 0
        if gestureEnded {
            if phase == .ended { momentum.release(at: timestamp) } else { momentum.stop() }
        }
        if suppressClicks {
            outputs.removeAll(where: \.isClick)
        }
        if gestureEnded {
            suppressClicks = false
            if peakTouches >= 3 {
                IPhoneDebugLog.emit("trackpad_multitouch", ["peak": "\(peakTouches)"])
            }
            peakTouches = 0
        }
        onOutputs?(outputs)
        scheduleDragRelease()
        publishOneFingerScroll()
    }

    private func scheduleDragRelease() {
        dragReleaseTimer?.invalidate()
        dragReleaseTimer = nil
        guard engine.isDragSuspended else { return }
        dragReleaseTimer = Timer.scheduledTimer(
            withTimeInterval: engine.configuration.dragLiftGrace,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragReleaseTimer = nil
                // A timer never fires early, and the engine reads the same
                // clock the touches carry, so the window has really passed.
                self.onOutputs?(self.engine.flushSuspendedDrag(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func publishOneFingerScroll() {
        let scrolling = engine.isOneFingerScrolling
        guard scrolling != oneFingerScrolling else { return }
        oneFingerScrolling = scrolling
        onOneFingerScrollChanged?(scrolling)
    }

    private func scrollTravel(in outputs: [RemoteInputEvent]) -> Double {
        outputs.reduce(into: 0.0) { total, output in
            if case let .scroll(delta) = output { total += delta.y }
        }
    }

}

private extension RemoteInputEvent {
    var isClick: Bool {
        switch self {
        case .leftClick, .rightClick, .doubleClick:
            return true
        case .pointer, .scroll, .dragBegan, .dragEnded, .missionControl, .appExpose:
            return false
        }
    }
}
#endif
