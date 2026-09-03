#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit

/// A plain UIView sees `touchesBegan` the moment the finger lands.  A SwiftUI
/// gesture waits on recognizer arbitration with every ancestor first, which is
/// dead time no audio change can recover.
final class PushToTalkTouchView: UIView {
    var onPress: (() -> Void)?
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

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onRelease?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onRelease?()
    }
}

struct PushToTalkTouchSurface: UIViewRepresentable {
    let press: () -> Void
    let release: () -> Void

    func makeUIView(context: Context) -> PushToTalkTouchView {
        let view = PushToTalkTouchView(frame: .zero)
        view.onPress = press
        view.onRelease = release
        return view
    }

    func updateUIView(_ view: PushToTalkTouchView, context: Context) {
        view.onPress = press
        view.onRelease = release
    }
}
#endif
