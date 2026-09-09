#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
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
///
/// It wears the four keys rather than a single symbol, because the four keys
/// are what the gesture does: a thumb that can see them has been told to hold
/// and swipe without a word of instruction.  The Mac draws the same four while
/// the key is held, so the far screen says which way the caret just went.
struct ArrowPadKey: View {
    let send: (RemoteHotkey) -> Void
    let arrows: (ArrowPadPhase) -> Void

    /// The keycaps have to fit three across inside one key, so they are sized
    /// off the key rather than off the type in them.
    private static let capSide: Double = 16
    private static let capSpacing: Double = 2

    @State private var tracker = SlideStepTracker(sensitivity: SlideStepTracker.aimingSensitivity)
    @State private var press = ArrowPadPress()
    @State private var keepalive = HeldKeyKeepalive<ArrowPadPayload>()

    var body: some View {
        keycaps
            .frame(width: RemoteKeyMetrics.keyWidth, height: RemoteKeyMetrics.keyHeight)
            .background(press.hasBegun ? Color.accentColor : Color(.tertiarySystemFill))
            .foregroundStyle(press.hasBegun ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .holdSlide("arrow_pad", spokenName: "Arrows. Hold and drag to move the cursor.", onPhase: handle)
            // A key that leaves the screen mid-press takes its heartbeat with
            // it; the Mac's silence timeout then closes the card on its own.
            .onDisappear { keepalive.stop() }
    }

    /// The keyboard's own inverted T, so the key reads as the arrow cluster it
    /// stands in for rather than as four directions in a row.
    private var keycaps: some View {
        VStack(spacing: Self.capSpacing) {
            cap("arrowtriangle.up.fill")
            HStack(spacing: Self.capSpacing) {
                cap("arrowtriangle.left.fill")
                cap("arrowtriangle.down.fill")
                cap("arrowtriangle.right.fill")
            }
        }
    }

    /// The cap borrows its colour from the key, so both states need only the
    /// one wash behind the glyph to keep it off the flat background.
    private func cap(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .frame(width: Self.capSide, height: Self.capSide)
            .background(
                Color.primary.opacity(press.hasBegun ? 0 : 0.08),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(press.hasBegun ? 0.35 : 0.15), lineWidth: 1)
            )
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            guard let message = press.begin() else { return }
            tracker = SlideStepTracker(sensitivity: SlideStepTracker.aimingSensitivity)
            arrows(message.phase)
            keepalive.start(press.keepalive) { arrows($0.phase) }
            Haptics.play(.press)
        case let .moved(translationX, translationY):
            guard press.hasBegun else { return }
            for step in tracker.advance(translationX: translationX, translationY: translationY) {
                send(step.arrowHotkey)
                // The tick is how the hand counts the steps it has taken.
                Haptics.play(.step)
            }
        case .ended, .cancelled:
            guard let message = press.lift() else { return }
            keepalive.stop()
            arrows(message.phase)
            Haptics.play(.release)
        }
    }
}
#endif
