#if canImport(UIKit) && os(iOS)
import UIKit

/// Every buzz the remote makes, in one place, so a press on the trackpad and a
/// press on a key feel like the same device.  Generators are kept alive and
/// re-prepared after each play: an unprepared generator takes about 100 ms to
/// fire, which is most of the delay the buzz is there to hide.
@MainActor
public enum Haptics {
    public enum Feedback: Equatable, Sendable {
        /// A key, toggle, or hold going down.
        case press
        /// The same control coming back up.  Softer, so a press and its release
        /// are not one event to the hand.
        case release
        /// A gesture region took the finger: a side scroll strip, or the hold
        /// clutch turning travel into scroll.
        case gestureBegan
        /// That region let the finger go.
        case gestureEnded
        /// One notch of a continuous control, like walking the app switcher.
        case step
    }

    /// Warms the generators for a screen that is about to be touched.
    public static func prepare() {
        for style in ImpactStyle.allCases {
            generator(for: style).prepare()
        }
        selection.prepare()
    }

    public static func play(_ feedback: Feedback) {
        switch feedback {
        case .press:
            impact(.medium, intensity: 1.0)
        case .release:
            impact(.medium, intensity: 0.5)
        case .gestureBegan:
            impact(.rigid, intensity: 0.9)
        case .gestureEnded:
            impact(.soft, intensity: 0.4)
        case .step:
            selection.selectionChanged()
            selection.prepare()
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

    private enum ImpactStyle: CaseIterable {
        case medium
        case rigid
        case soft

        var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .medium: return .medium
            case .rigid: return .rigid
            case .soft: return .soft
            }
        }
    }

    private static var impacts: [ImpactStyle: UIImpactFeedbackGenerator] = [:]
    private static let selection = UISelectionFeedbackGenerator()

    private static func impact(_ style: ImpactStyle, intensity: CGFloat) {
        let generator = generator(for: style)
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }

    private static func generator(for style: ImpactStyle) -> UIImpactFeedbackGenerator {
        if let existing = impacts[style] { return existing }
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        impacts[style] = generator
        return generator
    }
}
#endif
