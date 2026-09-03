#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

public extension SlideStep {
    var arrowHotkey: RemoteHotkey {
        switch self {
        case .left: return .arrowLeft
        case .right: return .arrowRight
        case .up: return .arrowUp
        case .down: return .arrowDown
        }
    }
}

/// Hold and drag to walk the arrow keys.  It is the selection key's gesture
/// with the Shift left off: each notch is one plain arrow, so the same drag
/// that would pick up text instead moves the caret through it.
struct ArrowPadKey: View {
    let send: (RemoteHotkey) -> Void

    @State private var tracker = SlideStepTracker()
    @State private var isHeld = false

    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.title3)
            .frame(width: RemoteKeyMetrics.keyWidth, height: RemoteKeyMetrics.keyHeight)
            .background(isHeld ? Color.accentColor : Color(.tertiarySystemFill))
            .foregroundStyle(isHeld ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .holdSlide("arrow_pad", spokenName: "Arrows. Hold and drag to move the cursor.", onPhase: handle)
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            guard !isHeld else { return }
            isHeld = true
            tracker = SlideStepTracker()
            Haptics.play(.press)
        case let .moved(translationX, translationY):
            guard isHeld else { return }
            for step in tracker.advance(translationX: translationX, translationY: translationY) {
                send(step.arrowHotkey)
                // The tick is how the hand counts the steps it has taken.
                Haptics.play(.step)
            }
        case .ended, .cancelled:
            guard isHeld else { return }
            isHeld = false
            Haptics.play(.release)
        }
    }
}
#endif
