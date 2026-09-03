import Foundation

/// Paces trackpad pointer packets to what the BLE link can carry and keeps
/// every other output ordered behind the motion that preceded it.
final class TrackpadOutputCoalescer {
    /// One pointer delta costs a 206-byte JSON envelope plus 60 bytes of AEAD
    /// plus a 16-byte BLE frame header, so the radio and not the digitizer sets
    /// the useful rate.  16 ms holds it near 60 packets/s and costs at most one
    /// extra packet interval of latency versus sending every touch sample.
    static let defaultInterval: TimeInterval = 0.016

    var onOutput: ((TrackpadOutput) -> Void)?
    let pointerCoalescer: DeltaCoalescer<TrackpadPointerDelta>

    init(interval: TimeInterval = defaultInterval) {
        pointerCoalescer = DeltaCoalescer(minimumInterval: interval) {
            TrackpadPointerDelta(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        pointerCoalescer.onFlush = { [weak self] delta in
            self?.onOutput?(.pointer(delta))
        }
    }

    func handle(_ outputs: [TrackpadOutput]) {
        for output in outputs {
            if case let .pointer(delta) = output {
                pointerCoalescer.send(delta)
            } else {
                pointerCoalescer.flushNow()
                onOutput?(output)
            }
        }
    }
}
