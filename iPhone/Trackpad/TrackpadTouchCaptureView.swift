#if canImport(UIKit)
import UIKit

/// UIKit-only adapter.  Gesture semantics remain in TrackpadGestureEngine;
/// this view forwards touch batches and never emits protocol messages itself.
public final class TrackpadTouchCaptureView: UIView {
    public var onOutputs: (([TrackpadOutput]) -> Void)?
    public var onLifecycle: ((TrackpadLifecycle) -> Void)?
    public var engine = TrackpadGestureEngine()

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
        onOutputs?(engine.handle(values))
    }
}
#endif
