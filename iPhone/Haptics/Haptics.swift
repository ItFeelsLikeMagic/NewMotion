#if canImport(UIKit) && os(iOS)
import UIKit

/// Every buzz the remote makes, in one place, so a key press and a gesture feel
/// like the same device.  The generators are kept alive and re-prepared after
/// each play: an unprepared one takes about 100 ms to fire, which is most of
/// the delay the buzz is there to hide.
///
/// The app holds a recording audio session open, which mutes the Taptic Engine
/// unless the session opts back in; see `AudioCaptureSession.bringUp`.
@MainActor
public enum Haptics {
    public enum Feedback {
        /// A key, toggle, or hold going down.
        case press
        /// The same control coming back up.  Softer, so a press and its release
        /// are not one event to the hand.
        case release
        /// A gesture region took the finger: a side scroll strip.
        case gestureBegan
        /// That region let the finger go.
        case gestureEnded
        /// One notch of a continuous control, like walking the app switcher.
        case step
        /// A control changed what it does.  The heaviest thing the remote
        /// plays, because it is the one buzz that has to be felt through a
        /// slide that is already ticking.
        case modeChange
    }

    /// Warms the generators for a screen that is about to be touched.
    public static func prepare() {
        press.prepare()
        modeChange.prepare()
        gestureBegan.prepare()
        gestureEnded.prepare()
        step.prepare()
    }

    public static func play(_ feedback: Feedback) {
        switch feedback {
        case .press:
            impact(press, intensity: 1.0)
        case .release:
            impact(press, intensity: 0.5)
        case .gestureBegan:
            impact(gestureBegan, intensity: 0.9)
        case .gestureEnded:
            impact(gestureEnded, intensity: 0.4)
        case .step:
            step.selectionChanged()
            step.prepare()
        case .modeChange:
            impact(modeChange, intensity: 1.0)
        }
    }

    /// Wraps a button action so the tap is felt as it is sent.  Call sites stay
    /// one line: `Button(action: Haptics.tap { send(hotkey) })`.
    public static func tap(_ action: @escaping () -> Void) -> () -> Void {
        {
            play(.press)
            action()
        }
    }

    private static let press = UIImpactFeedbackGenerator(style: .medium)
    private static let gestureBegan = UIImpactFeedbackGenerator(style: .rigid)
    private static let gestureEnded = UIImpactFeedbackGenerator(style: .soft)
    private static let step = UISelectionFeedbackGenerator()
    private static let modeChange = UIImpactFeedbackGenerator(style: .heavy)

    private static func impact(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }
}
#endif
