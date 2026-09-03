import Foundation

/// Merges cursor travel from every sensor into one paced stream and keeps
/// every other event ordered behind the travel that preceded it.  Sensors do
/// their own tuning upstream, in their own units; by the time travel arrives
/// here it is points, and where it came from no longer matters.
final class CursorMixer {
    /// The link, not the sensor, sets the useful rate: one packet carries a
    /// delta of any size, so more packets buy nothing but airtime.  16 ms holds
    /// it near 60 a second and costs at most one packet interval of latency
    /// against sending every sample.
    static let defaultInterval: TimeInterval = 0.016

    var onEvent: ((RemoteInputEvent) -> Void)?
    let travelCoalescer: DeltaCoalescer<CursorDelta>

    init(interval: TimeInterval = defaultInterval) {
        travelCoalescer = DeltaCoalescer(minimumInterval: interval) {
            CursorDelta(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        travelCoalescer.onFlush = { [weak self] delta in
            self?.onEvent?(.pointer(delta))
        }
    }

    /// Travel from a sensor that produces nothing else, such as the air mouse.
    func handleTravel(_ delta: CursorDelta) {
        travelCoalescer.send(delta)
    }

    func handle(_ events: [RemoteInputEvent]) {
        for event in events {
            if case let .pointer(delta) = event {
                travelCoalescer.send(delta)
            } else {
                travelCoalescer.flushNow()
                onEvent?(event)
            }
        }
    }
}
