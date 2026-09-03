import Foundation

public struct MotionVector3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = MotionVector3(x: 0, y: 0, z: 0)

    fileprivate static func + (lhs: MotionVector3, rhs: MotionVector3) -> MotionVector3 {
        MotionVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    fileprivate static func * (lhs: MotionVector3, rhs: Double) -> MotionVector3 {
        MotionVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    fileprivate var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

public struct MotionQuaternion: Equatable, Sendable {
    public let w: Double
    public let x: Double
    public let y: Double
    public let z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = MotionQuaternion(w: 1, x: 0, y: 0, z: 0)

    fileprivate var isFinite: Bool {
        w.isFinite && x.isFinite && y.isFinite && z.isFinite
    }

    fileprivate var normalized: MotionQuaternion? {
        guard isFinite else { return nil }
        let norm = (w * w + x * x + y * y + z * z).squareRoot()
        guard norm.isFinite, norm >= 1e-9 else { return nil }
        return MotionQuaternion(w: w / norm, x: x / norm, y: y / norm, z: z / norm)
    }

    fileprivate var conjugate: MotionQuaternion {
        MotionQuaternion(w: w, x: -x, y: -y, z: -z)
    }

    fileprivate static func * (lhs: MotionQuaternion, rhs: MotionQuaternion) -> MotionQuaternion {
        MotionQuaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        )
    }

    /// Converts a unit quaternion into a shortest-axis rotation vector.
    fileprivate var rotationVector: MotionVector3 {
        let positive = w < 0 ? MotionQuaternion(w: -w, x: -x, y: -y, z: -z) : self
        let scalar = min(1, max(-1, positive.w))
        let halfAngle = acos(scalar)
        let sine = sin(halfAngle)
        guard sine > 1e-8 else {
            return MotionVector3(x: positive.x * 2, y: positive.y * 2, z: positive.z * 2)
        }
        let scale = (2 * halfAngle) / sine
        return MotionVector3(x: positive.x * scale, y: positive.y * scale, z: positive.z * scale)
    }
}

public struct MotionSample: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let attitude: MotionQuaternion

    public init(timestamp: TimeInterval, attitude: MotionQuaternion) {
        self.timestamp = timestamp
        self.attitude = attitude
    }
}

public struct MotionPointerDelta: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Per-sample rotation at 100 Hz: a slow 5 deg/s wrist turn is about 0.0009 rad
/// per sample, so the dead zone must stay well under that or slow aiming
/// never registers. Gain is linear so slow moves keep their precision.
public struct MotionFilterConfiguration: Equatable, Sendable {
    public var sensitivity: Double
    public var deadZoneRadians: Double
    public var smoothingAlpha: Double
    public var accelerationExponent: Double
    public var accelerationScale: Double
    public var maxOutputPerSample: Double
    public var maximumSampleGap: TimeInterval
    public var maximumRotationPerSample: Double

    public init(
        sensitivity: Double = 2_400,
        deadZoneRadians: Double = 0.0004,
        smoothingAlpha: Double = 0.88,
        accelerationExponent: Double = 1.0,
        accelerationScale: Double = 1.0,
        maxOutputPerSample: Double = 400,
        maximumSampleGap: TimeInterval = 0.20,
        maximumRotationPerSample: Double = 1.5
    ) {
        self.sensitivity = min(max(sensitivity, 0), 8_000)
        self.deadZoneRadians = min(max(deadZoneRadians, 0), 0.25)
        self.smoothingAlpha = min(max(smoothingAlpha, 0.01), 1)
        self.accelerationExponent = min(max(accelerationExponent, 1), 2.5)
        self.accelerationScale = min(max(accelerationScale, 0), 10)
        self.maxOutputPerSample = min(max(maxOutputPerSample, 1), 1_000)
        self.maximumSampleGap = min(max(maximumSampleGap, 0.02), 2)
        self.maximumRotationPerSample = min(max(maximumRotationPerSample, 0.05), Double.pi)
    }
}

/// Converts fused attitude differences into bounded relative pointer motion.
/// It consumes orientation deltas rather than integrating acceleration, so a
/// stationary phone cannot accumulate unbounded cursor drift.
public struct MotionPointerFilter: Sendable {
    public private(set) var configuration: MotionFilterConfiguration
    public private(set) var clutchActive: Bool = false
    public private(set) var referenceOrientation: MotionQuaternion?
    public private(set) var acceptedSampleCount: UInt64 = 0
    public private(set) var rejectedSampleCount: UInt64 = 0

    private var previousOrientation: MotionQuaternion?
    private var previousTimestamp: TimeInterval?
    private var smoothedDelta = MotionVector3.zero

    public init(configuration: MotionFilterConfiguration = MotionFilterConfiguration()) {
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: MotionFilterConfiguration) {
        self.configuration = configuration
        smoothedDelta = .zero
    }

    /// Activating the clutch resets the relative reference on the next valid
    /// sample. Releasing it immediately freezes output.
    public mutating func setClutch(active: Bool) {
        guard clutchActive != active else { return }
        clutchActive = active
        referenceOrientation = nil
        previousOrientation = nil
        previousTimestamp = nil
        smoothedDelta = .zero
    }

    public mutating func resetReference() {
        referenceOrientation = nil
        previousOrientation = nil
        previousTimestamp = nil
        smoothedDelta = .zero
    }

    @discardableResult
    public mutating func process(_ sample: MotionSample) -> MotionPointerDelta? {
        guard clutchActive,
              sample.timestamp.isFinite,
              let orientation = sample.attitude.normalized else {
            rejectedSampleCount += 1
            return nil
        }

        if let previousTimestamp {
            let gap = sample.timestamp - previousTimestamp
            guard gap > 0, gap <= configuration.maximumSampleGap else {
                rejectedSampleCount += 1
                self.previousTimestamp = sample.timestamp
                self.previousOrientation = nil
                self.referenceOrientation = nil
                smoothedDelta = .zero
                return nil
            }
        }

        previousTimestamp = sample.timestamp
        acceptedSampleCount += 1
        guard let previousOrientation else {
            self.previousOrientation = orientation
            self.referenceOrientation = orientation
            return nil
        }
        self.previousOrientation = orientation

        let relative = (previousOrientation.conjugate * orientation).normalized
        guard let relative else {
            rejectedSampleCount += 1
            resetReference()
            return nil
        }
        let rotation = relative.rotationVector
        guard rotation.magnitude <= configuration.maximumRotationPerSample else {
            rejectedSampleCount += 1
            resetReference()
            return nil
        }

        // Pitch (x) drives vertical cursor motion. Yaw (z) drives horizontal.
        // Both signs are flipped so pointing the phone up/right moves the
        // Mac cursor up/right (CGEvent +Y is down).
        let raw = MotionVector3(x: -rotation.z, y: -rotation.x, z: 0)
        let deadZoned = MotionVector3(
            x: applyDeadZone(raw.x),
            y: applyDeadZone(raw.y),
            z: 0
        )
        smoothedDelta = smoothedDelta * (1 - configuration.smoothingAlpha) +
            deadZoned * configuration.smoothingAlpha

        let outputX = accelerated(smoothedDelta.x)
        let outputY = accelerated(smoothedDelta.y)
        guard outputX != 0 || outputY != 0 else { return nil }
        return MotionPointerDelta(x: clamp(outputX), y: clamp(outputY))
    }

    private func applyDeadZone(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let magnitude = abs(value)
        guard magnitude > configuration.deadZoneRadians else { return 0 }
        return value.sign == .minus ? -(magnitude - configuration.deadZoneRadians) : magnitude - configuration.deadZoneRadians
    }

    private func accelerated(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        let magnitude = pow(abs(value), configuration.accelerationExponent) *
            configuration.sensitivity * configuration.accelerationScale
        return value.sign == .minus ? -magnitude : magnitude
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, -configuration.maxOutputPerSample), configuration.maxOutputPerSample)
    }
}

public protocol MotionPointerOutputSink: AnyObject {
    func send(_ delta: MotionPointerDelta)
}
