import Foundation

/// Glide after a two-finger flick.  The model is pure so the decay curve can be
/// tested without a display link; the capture view drives it one frame at a
/// time and stops it as soon as a finger touches the glass again.
public struct ScrollMomentum: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Share of the velocity that survives one second of coasting. Tighter
        /// than a scroll view's, because a remote flick that keeps going after
        /// the finger stops reads as lag rather than as glide.
        public var retainedPerSecond: Double
        /// Below this the flick was a slow drag and should simply stop.
        public var minimumStartVelocity: Double
        /// Below this the glide is invisible, so it ends.
        public var minimumVelocity: Double
        public var maximumVelocity: Double

        public init(
            retainedPerSecond: Double = 0.03,
            minimumStartVelocity: Double = 80,
            minimumVelocity: Double = 25,
            maximumVelocity: Double = 6_000
        ) {
            self.retainedPerSecond = min(max(retainedPerSecond, 0.001), 0.9)
            self.minimumStartVelocity = max(1, minimumStartVelocity)
            self.minimumVelocity = max(1, minimumVelocity)
            self.maximumVelocity = max(minimumStartVelocity, maximumVelocity)
        }
    }

    public let configuration: Configuration
    public private(set) var velocity: Double = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isActive: Bool { velocity != 0 }

    /// Returns false when the flick was too slow to be worth coasting.
    @discardableResult
    public mutating func begin(velocity: Double) -> Bool {
        guard velocity.isFinite, abs(velocity) >= configuration.minimumStartVelocity else {
            self.velocity = 0
            return false
        }
        let capped = min(abs(velocity), configuration.maximumVelocity)
        self.velocity = velocity < 0 ? -capped : capped
        return true
    }

    public mutating func stop() {
        velocity = 0
    }

    /// Advances the glide by `elapsed` seconds and returns the scroll for that
    /// frame, or nil once the glide has ended.
    public mutating func step(elapsed: TimeInterval) -> ScrollDelta? {
        guard isActive, elapsed.isFinite, elapsed > 0 else { return nil }
        let travel = velocity * elapsed
        velocity *= pow(configuration.retainedPerSecond, elapsed)
        if abs(velocity) < configuration.minimumVelocity { velocity = 0 }
        guard travel != 0 else { return nil }
        return ScrollDelta(x: 0, y: travel)
    }
}
