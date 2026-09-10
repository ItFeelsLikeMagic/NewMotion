#if canImport(UIKit) && os(iOS)
import SwiftUI
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
        /// One notch of a continuous control, like walking the app switcher or
        /// dragging a slider.
        case step
        /// One notch of a control whose notches are each a different thing, like
        /// a cell of the chord grid.  Firmer, because the thumb is counting
        /// them, but no firmer than a key going down.
        case firmStep
        /// A control changed what it does.  The heaviest thing the remote
        /// plays, because it is the one buzz that has to be felt through a
        /// slide that is already ticking.
        case modeChange
        /// Something the phone was waiting on finished: a Mac paired.
        case success
        /// Something the person was watching failed: a scan that did not pair.
        /// Not for a retry they never asked for; a pocket should stay quiet.
        case failure
    }

    /// Warms the generators for a screen that is about to be touched.
    public static func prepare() {
        press.prepare()
        release.prepare()
        modeChange.prepare()
        gestureBegan.prepare()
        gestureEnded.prepare()
        step.prepare()
        firmStep.prepare()
        outcome.prepare()
    }

    public static func play(_ feedback: Feedback) {
        switch feedback {
        case .press:
            impact(press, intensity: 1.0)
        case .release:
            impact(release, intensity: 0.5)
        case .gestureBegan:
            impact(gestureBegan, intensity: 0.9)
        case .gestureEnded:
            impact(gestureEnded, intensity: 0.4)
        case .step:
            step.selectionChanged()
            step.prepare()
        case .firmStep:
            impact(firmStep, intensity: 0.8)
        case .modeChange:
            impact(modeChange, intensity: 1.0)
        case .success:
            notify(.success)
        case .failure:
            notify(.error)
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

    /// The same idea for a control that has no action to hang `tap` on: a
    /// slider, a toggle, a picker.  Only a real change is felt, because a drag
    /// writes the value it is already on more than once.
    public static func feel<Value: Equatable>(
        _ feedback: Feedback,
        _ binding: Binding<Value>
    ) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                if value != binding.wrappedValue { play(feedback) }
                binding.wrappedValue = value
            }
        )
    }

    private static let press = UIImpactFeedbackGenerator(style: .medium)
    private static let release = UIImpactFeedbackGenerator(style: .medium)
    private static let gestureBegan = UIImpactFeedbackGenerator(style: .rigid)
    private static let gestureEnded = UIImpactFeedbackGenerator(style: .soft)
    private static let step = UISelectionFeedbackGenerator()
    private static let firmStep = UIImpactFeedbackGenerator(style: .rigid)
    private static let modeChange = UIImpactFeedbackGenerator(style: .heavy)
    private static let outcome = UINotificationFeedbackGenerator()

    private static func impact(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }

    private static func notify(_ kind: UINotificationFeedbackGenerator.FeedbackType) {
        outcome.notificationOccurred(kind)
        outcome.prepare()
    }
}
#endif
