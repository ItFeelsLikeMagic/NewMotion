#if canImport(UIKit)
import QuartzCore
import UIKit

/// Drives `ScrollMomentum` one display frame at a time.  The decay curve stays
/// a pure struct so it can be tested without a clock; this owns the clock and
/// nothing else, which is what lets a finger flick and a released air-mouse
/// scroll coast on exactly the same curve.
public final class ScrollMomentumDriver {
    /// A flick whose last scroll landed longer ago than this was a hand that
    /// had already stopped, so it should not coast.
    public static let flickWindow: TimeInterval = 0.06
    public static let defaultStrength = 0.5

    /// Maps a 0 to 1 dial onto the share of speed that survives a second of
    /// coasting.  The curve is exponential because glide length is felt that
    /// way, and 0.5 lands on the value the glide shipped with.
    public static func configuration(for strength: Double) -> ScrollMomentum.Configuration {
        let clamped = min(max(strength, 0), 1)
        return ScrollMomentum.Configuration(retainedPerSecond: 0.002 * pow(250, clamped))
    }

    public var onStep: ((ScrollDelta) -> Void)?

    /// Zero means a flick simply stops when the hand does.
    public var strength: Double = ScrollMomentumDriver.defaultStrength {
        didSet {
            guard strength != oldValue else { return }
            stop()
            momentum = ScrollMomentum(configuration: Self.configuration(for: strength))
        }
    }

    private var momentum = ScrollMomentum(configuration: configuration(for: defaultStrength))
    /// The run loop retains the link's target, so every path out of a glide has
    /// to invalidate it or this object keeps itself alive.
    private var link: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var velocity: Double = 0
    private var lastSampleTime: TimeInterval?

    public init() {}

    public var isActive: Bool { momentum.isActive }

    /// Feeds one scroll sample so the glide knows how fast the hand was moving.
    /// Weighted towards the newest sample so a flick at the end of a slow drag
    /// still coasts, while one stray fast frame cannot dominate.
    public func track(travel: Double, at timestamp: TimeInterval) {
        guard travel != 0 else { return }
        defer { lastSampleTime = timestamp }
        guard let lastSampleTime, timestamp > lastSampleTime else { return }
        let sample = travel / (timestamp - lastSampleTime)
        velocity = velocity == 0 ? sample : sample * 0.7 + velocity * 0.3
    }

    /// Coasts from the tracked velocity, if the hand was still moving when it
    /// let go.  The tracked flick is cleared either way.
    @discardableResult
    public func release(at timestamp: TimeInterval) -> Bool {
        let flickVelocity = velocity
        let sampledAt = lastSampleTime
        clearTracking()
        guard strength > 0, let sampledAt, timestamp - sampledAt <= Self.flickWindow else { return false }
        guard momentum.begin(velocity: flickVelocity) else { return false }
        lastFrameTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        // The link is only a packet source; 60 Hz already saturates what the
        // BLE link carries and halves the traffic of a ProMotion refresh.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        return true
    }

    public func stop() {
        momentum.stop()
        link?.invalidate()
        link = nil
        clearTracking()
    }

    private func clearTracking() {
        velocity = 0
        lastSampleTime = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = link.timestamp - lastFrameTime
        lastFrameTime = link.timestamp
        guard let delta = momentum.step(elapsed: elapsed) else {
            stop()
            return
        }
        onStep?(delta)
    }
}
#endif
