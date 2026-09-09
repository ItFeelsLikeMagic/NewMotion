#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The delete key, which is also a dial.  A tap rubs out one unit.  Holding it
/// and sliding left rubs out one unit at a time, with a tick for each; sliding
/// back brings that text back.  Sliding up switches the unit from a character
/// to a word, sliding down switches it back, and every new press starts back
/// on characters.
///
/// The press announces itself the moment the key goes down, before anything
/// has been asked for, because that is when the Mac starts waking the focused
/// field and a Chromium field takes seconds to wake.  A tap therefore costs
/// three small messages instead of one, which is nothing beside the cursor.
///
/// What the press owes the Mac lives in `DeleteScrubPress`, so the whole
/// gesture can be tested without a touch; this view is the glass and the hand.
struct DeleteScrubKey: View {
    let send: (RemoteHotkey) -> Void
    let scrub: (DeleteScrubPhase, DeleteScrubGranularity) -> Void

    @State private var press = DeleteScrubPress()

    var body: some View {
        label
            .heldKeyStyle(isHeld: press.hasBegun)
            // The count is always in the tree and only fades, because swapping
            // it in and out rebuilds the surface below: the removed view leaves
            // the window, which reads as a cancelled press, and the slide dies
            // after its first notch.
            .overlay(alignment: .topTrailing) { count }
            .holdSlide(
                "delete_scrub",
                spokenName: "\(press.hotkey.spokenName). Hold and slide left to erase, right to undo, up for words.",
                onPhase: handle
            )
    }

    /// The unit is named on the key, because it is the one thing about the key
    /// that changes and nothing else on the phone says which way it is set.
    private var label: some View {
        VStack(spacing: 2) {
            Image(systemName: "delete.left")
            Text(press.isWord ? "word" : "char")
                .font(.caption2)
        }
    }

    private var count: some View {
        Text("\(press.steps)")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.35), in: Capsule())
            .padding(2)
            .opacity(press.steps > 0 ? 1 : 0)
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            dispatch(press.begin())
        case let .moved(translationX, translationY):
            dispatch(press.move(translationX: translationX, translationY: translationY))
        case .ended:
            finish(committing: true)
        case .cancelled:
            finish(committing: false)
        }
    }

    private func finish(committing: Bool) {
        guard press.hasBegun else { return }
        // Read before the lift, which empties the press.
        let steps = press.steps
        let slid = press.hasStepped
        let unit = press.isWord ? "word" : "character"
        dispatch(press.lift(committing: committing))
        IPhoneDebugLog.emit("delete_scrub", [
            "steps": "\(steps)",
            "slid": slid ? "yes" : "no",
            "unit": unit
        ])
    }

    private func dispatch(_ messages: [DeleteScrubPress.Message]) {
        for message in messages {
            switch message {
            case let .scrub(phase, granularity):
                scrub(phase, granularity)
                if let feel = Self.feel(for: phase) { Haptics.play(feel) }
            case let .key(hotkey):
                send(hotkey)
            }
        }
    }

    /// The tick is the whole point: it is how a thumb counts characters off a
    /// screen it is not looking at.  Coming back gets a softer thud, so the two
    /// directions are not one event to the hand, and a unit flip gets a third
    /// feel again because it changes what every later notch takes.  The lift
    /// is silent: the finger already knows it lifted.
    private static func feel(for phase: DeleteScrubPhase) -> Haptics.Feedback? {
        switch phase {
        case .begin: return .press
        case .delete: return .step
        case .restore: return .release
        case .unitChanged: return .modeChange
        case .end: return nil
        }
    }
}
#endif
