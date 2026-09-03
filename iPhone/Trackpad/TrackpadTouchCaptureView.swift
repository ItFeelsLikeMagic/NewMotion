#if canImport(UIKit)
import UIKit

/// UIKit-only adapter.  Gesture semantics remain in TrackpadGestureEngine and
/// the glide curve in ScrollMomentum; this view only supplies touches, frame
/// timing, and never emits protocol messages itself.
public final class TrackpadTouchCaptureView: UIView {
    /// A flick whose last scroll landed longer ago than this was a finger that
    /// had already stopped, so it should not coast.
    private static let flickWindow: TimeInterval = 0.06

    public var onOutputs: (([RemoteInputEvent]) -> Void)?
    public var onLifecycle: ((TrackpadLifecycle) -> Void)?
    public var engine = TrackpadGestureEngine()

    private var momentum = ScrollMomentum()
    /// Zero means a flick simply stops when the finger lifts.
    public var momentumStrength: Double = TrackpadTouchCaptureView.defaultMomentumStrength {
        didSet {
            guard momentumStrength != oldValue else { return }
            momentum = ScrollMomentum(configuration: Self.momentumConfiguration(for: momentumStrength))
        }
    }

    public static let defaultMomentumStrength = 0.5

    /// Maps a 0 to 1 dial onto the share of speed that survives a second of
    /// coasting.  The curve is exponential because glide length is felt that
    /// way, and 0.5 lands on the value the glide shipped with.
    static func momentumConfiguration(for strength: Double) -> ScrollMomentum.Configuration {
        let clamped = min(max(strength, 0), 1)
        return ScrollMomentum.Configuration(retainedPerSecond: 0.002 * pow(250, clamped))
    }
    /// The run loop retains the link's target, so leaving the window must
    /// invalidate it or the view would keep itself alive.
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var scrollVelocity: Double = 0
    private var lastScrollTime: TimeInterval?
    /// The touch that stops a glide must not also click, the same way stopping
    /// a scrolling list on iOS does not tap what is under the finger.
    private var suppressClicks = false
    /// Three fingers are the one gesture whose silence is ambiguous: nothing
    /// downstream fires unless the swipe is long enough, so the count itself is
    /// logged to separate a short swipe from touches that never arrived.
    private var peakTouches = 0

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
        stopMomentum()
        if window == nil {
            onOutputs?(engine.handle(.cancel))
        } else {
            onOutputs?(engine.handle(.foreground))
        }
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
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    private func forward(_ touches: Set<UITouch>, phase: TrackpadTouchPhase) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        if phase == .began {
            if momentum.isActive { suppressClicks = true }
            stopMomentum()
            if engine.activeTouchCount == 0 {
                scrollVelocity = 0
                lastScrollTime = nil
            }
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
        trackScrollVelocity(in: outputs, at: timestamp)

        let gestureEnded = engine.activeTouchCount == 0
        if gestureEnded, phase == .ended {
            startMomentum(at: timestamp)
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
    }

    private func trackScrollVelocity(in outputs: [RemoteInputEvent], at timestamp: TimeInterval) {
        let travel = outputs.reduce(into: 0.0) { total, output in
            if case let .scroll(delta) = output { total += delta.y }
        }
        guard travel != 0 else { return }
        defer { lastScrollTime = timestamp }
        guard let lastScrollTime, timestamp > lastScrollTime else { return }
        let sample = travel / (timestamp - lastScrollTime)
        // Weighted towards the newest sample so a flick at the end of a slow
        // drag still coasts, while one stray fast frame cannot dominate.
        scrollVelocity = scrollVelocity == 0 ? sample : sample * 0.7 + scrollVelocity * 0.3
    }

    private func startMomentum(at timestamp: TimeInterval) {
        defer {
            scrollVelocity = 0
            lastScrollTime = nil
        }
        // After the defer, so turning glide off still clears the flick state.
        guard momentumStrength > 0 else { return }
        guard let lastScrollTime, timestamp - lastScrollTime <= Self.flickWindow else { return }
        guard momentum.begin(velocity: scrollVelocity) else { return }
        lastFrameTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
        // The link is only a packet source; 60 Hz already saturates what the
        // BLE link carries and halves the traffic of a ProMotion refresh.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let elapsed = link.timestamp - lastFrameTime
        lastFrameTime = link.timestamp
        guard let delta = momentum.step(elapsed: elapsed) else {
            stopMomentum()
            return
        }
        onOutputs?([.scroll(delta)])
    }

    private func stopMomentum() {
        momentum.stop()
        displayLink?.invalidate()
        displayLink = nil
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
