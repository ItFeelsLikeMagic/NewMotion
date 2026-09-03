#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit

/// A plain UIView sees `touchesBegan` the moment the finger lands.  A SwiftUI
/// gesture waits on recognizer arbitration with every ancestor first, which is
/// dead time no audio change can recover.
final class PushToTalkTouchView: UIView {
    var onPress: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onRelease: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        isMultipleTouchEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // How long the touch spent in the system before reaching this line.
        // Everything else in the press path is measured from here on.
        if let stamp = event?.timestamp {
            let ms = Int((ProcessInfo.processInfo.systemUptime - stamp) * 1000)
            IPhoneDebugLog.emit("ptt_touch", ["lagMs": "\(ms)"])
        }
        onPress?()
    }

    /// The touch keeps coming here once it leaves the button, which is what
    /// lets a hold reach the cancel targets in the corners.  Window
    /// coordinates, so the reported zone frames can be compared directly.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        onDrag?(touch.location(in: nil))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onRelease?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onRelease?()
    }
}

struct PushToTalkTouchSurface: UIViewRepresentable {
    let press: () -> Void
    let drag: (CGPoint) -> Void
    let release: () -> Void

    func makeUIView(context: Context) -> PushToTalkTouchView {
        let view = PushToTalkTouchView(frame: .zero)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: PushToTalkTouchView, context: Context) {
        view.onPress = press
        view.onDrag = drag
        view.onRelease = release
    }
}
#endif
