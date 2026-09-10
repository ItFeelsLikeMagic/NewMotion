#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The walk key, which is also a dial.  Holding it opens the app switcher and
/// sliding across steps through it; sliding up swaps that row for the front
/// app's tabs, sliding down for its windows, and every new press starts back
/// on apps.  Lifting takes whatever the walk is standing on.
///
/// The key says the row in a picture and a word rather than in chord glyphs,
/// because what a thumb needs to know mid-press is what it is picking from,
/// not which keys the Mac is holding down to offer it.  It is built like the
/// delete key, which teaches the same thing: the picture says what the key
/// does, the word under it says which way the dial is set.
///
/// What the press owes the Mac lives in `TabWalkPress`, so the whole gesture
/// can be tested without a touch; this view is the glass and the hand.
struct TabWalkKey: View {
    let walk: (TabWalkPayload) -> Void

    @State private var press = TabWalkPress()

    var body: some View {
        label
            .keyFace(isHeld: press.hasBegun)
            .holdSlide("tab_walk", spokenName: spokenName, onPhase: handle)
    }

    private var label: some View {
        VStack(spacing: 2) {
            Image(systemName: press.row.symbolName)
            Text(press.row.displayName)
                .font(.caption2)
        }
    }

    private var spokenName: String {
        "\(press.row.displayName). Hold and slide to walk, up for tabs, down for windows."
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            dispatch(press.begin())
        case let .moved(translationX, translationY):
            dispatch(press.move(translationX: translationX, translationY: translationY))
        case .ended:
            dispatch(press.lift(committing: true))
        case .cancelled:
            dispatch(press.lift(committing: false))
        }
    }

    private func dispatch(_ messages: [TabWalkPayload]) {
        for message in messages {
            walk(message)
            if let feel = Self.feel(for: message.phase) { Haptics.play(feel) }
        }
    }

    /// A step gets the tick every hold-and-slide key ticks with, and a change
    /// of row gets the heaviest feel there is, because it changes what every
    /// later step walks.
    private static func feel(for phase: TabWalkPhase) -> Haptics.Feedback? {
        switch phase {
        case .begin: return .press
        case .next, .previous: return .step
        case .swap: return .modeChange
        case .commit, .cancel: return .release
        }
    }
}

private extension TabWalkRow {
    /// The Home Screen's own grid for apps, one pane behind another for tabs,
    /// and a window in front of a window for windows.
    var symbolName: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .tabs: return "square.on.square"
        case .windows: return "macwindow.on.rectangle"
        }
    }
}
#endif
