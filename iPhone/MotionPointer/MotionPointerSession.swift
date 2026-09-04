import Foundation

public enum MotionPointerStartResult: Equatable, Sendable {
    case started
    case unavailable
    case inactive
    case failed
}

public protocol DeviceMotionProviding: AnyObject {
    var isAvailable: Bool { get }
    func start(handler: @escaping (MotionSample) -> Void) throws
    func stop()
}

public protocol PhoneLifecycleStopping: AnyObject {
    func stopForLifecycle()
    func resumeForLifecycle()
}

extension PhoneLifecycleStopping {
    public func resumeForLifecycle() {}
}

/// Owns Core Motion lifecycle and emits the same relative pointer-delta shape
/// as TrackpadGestureEngine through an injected sink.
public final class MotionPointerSession {
    private let provider: DeviceMotionProviding
    private let sink: MotionPointerOutputSink
    private var filter: MotionPointerFilter
    private var appActive = false
    private var clutchHeld = false
    private var running = false

    public init(
        provider: DeviceMotionProviding,
        sink: MotionPointerOutputSink,
        filter: MotionPointerFilter = MotionPointerFilter()
    ) {
        self.provider = provider
        self.sink = sink
        self.filter = filter
    }

    public var isRunning: Bool { running }

    @discardableResult
    public func setAppActive(_ active: Bool) -> MotionPointerStartResult? {
        appActive = active
        if !active {
            stop()
            setClutchHeld(false)
            return nil
        }
        filter.setClutch(active: clutchHeld)
        return clutchHeld ? startIfNeeded() : nil
    }

    @discardableResult
    public func setClutchHeld(_ held: Bool) -> MotionPointerStartResult? {
        clutchHeld = held
        filter.setClutch(active: held && appActive)
        if !held {
            stop()
            return nil
        }
        return appActive ? startIfNeeded() : .inactive
    }

    public func updateFilter(_ configuration: MotionFilterConfiguration) {
        filter.updateConfiguration(configuration)
    }

    public func stop() {
        guard running else { return }
        provider.stop()
        running = false
    }

    private func startIfNeeded() -> MotionPointerStartResult {
        guard appActive, clutchHeld else { return .inactive }
        guard provider.isAvailable else { return .unavailable }
        guard !running else { return .started }
        do {
            try provider.start { [weak self] sample in
                self?.receive(sample)
            }
            running = true
            return .started
        } catch {
            running = false
            return .failed
        }
    }

    private func receive(_ sample: MotionSample) {
        guard appActive, clutchHeld, running else { return }
        guard let delta = filter.process(sample) else { return }
        sink.send(delta)
    }
}

/// Deterministic provider for simulator and unit tests.  A real app never
/// activates it; tests drive `emit(_:)` with recorded/synthetic attitudes.
public final class SimulatedDeviceMotionProvider: DeviceMotionProviding {
    public var isAvailable: Bool
    public private(set) var running = false
    private var handler: ((MotionSample) -> Void)?

    public init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    public func start(handler: @escaping (MotionSample) -> Void) throws {
        guard isAvailable else { throw MotionProviderError.unavailable }
        self.handler = handler
        running = true
    }

    public func stop() {
        running = false
        handler = nil
    }

    public func emit(_ sample: MotionSample) {
        guard running else { return }
        handler?(sample)
    }
}

public enum MotionProviderError: Error, Equatable, Sendable {
    case unavailable
}

extension MotionPointerSession: PhoneLifecycleStopping {
    public func stopForLifecycle() {
        _ = setAppActive(false)
    }
}

#if os(iOS)
import CoreMotion

/// Core Motion adapter.  The manager is sampled at 100 Hz while the phone app
/// is foregrounded and the clutch is held.
public final class CoreMotionDeviceProvider: DeviceMotionProviding {
    private let manager: CMMotionManager
    private let queue: OperationQueue

    public init(manager: CMMotionManager = CMMotionManager()) {
        self.manager = manager
        self.queue = OperationQueue()
        self.queue.name = "PhoneRemote.Motion"
        self.queue.qualityOfService = .userInteractive
        self.queue.maxConcurrentOperationCount = 1
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start(handler: @escaping (MotionSample) -> Void) throws {
        guard isAvailable else { throw MotionProviderError.unavailable }
        manager.deviceMotionUpdateInterval = 0.01
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { motion, _ in
            guard let motion else { return }
            let q = motion.attitude.quaternion
            handler(MotionSample(
                timestamp: motion.timestamp,
                attitude: MotionQuaternion(w: q.w, x: q.x, y: q.y, z: q.z)
            ))
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
#endif
