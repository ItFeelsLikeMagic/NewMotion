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
struct DeleteScrubKey: View {
    let send: (RemoteHotkey) -> Void
    let scrub: (DeleteScrubPhase, DeleteScrubGranularity) -> Void

    @State private var tracker = DeleteScrubTracker()
    @State private var latch = DeleteGranularityLatch()
    @State private var isHeld = false
    /// A press that changed the unit was about the unit, not about deleting,
    /// so it must not also rub a character out when the finger lifts.
    @State private var hasChangedUnit = false

    var body: some View {
        label
            .heldKeyStyle(isHeld: isHeld)
            // The count is always in the tree and only fades, because swapping
            // it in and out rebuilds the surface below: the removed view leaves
            // the window, which reads as a cancelled press, and the slide dies
            // after its first notch.
            .overlay(alignment: .topTrailing) { count }
            .holdSlide(
                "delete_scrub",
                spokenName: "\(hotkey.spokenName). Hold and slide left to erase, right to undo, up for words.",
                onPhase: handle
            )
    }

    private var granularity: DeleteScrubGranularity {
        latch.isWord ? .word : .character
    }

    private var hotkey: RemoteHotkey {
        latch.isWord ? .deleteWordBackward : .deleteBackward
    }

    /// The unit is named on the key, because it is the one thing about the key
    /// that changes and nothing else on screen says which way it is set.
    private var label: some View {
        VStack(spacing: 2) {
            Image(systemName: "delete.left")
            Text(latch.isWord ? "word" : "char")
                .font(.caption2)
        }
    }

    private var count: some View {
        Text("\(tracker.steps)")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.35), in: Capsule())
            .padding(2)
            .opacity(tracker.steps > 0 ? 1 : 0)
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            guard !isHeld else { return }
            isHeld = true
            hasChangedUnit = false
            tracker = DeleteScrubTracker()
            latch.reset()
            scrub(.begin, granularity)
            Haptics.play(.press)
        case let .moved(translationX, translationY):
            guard isHeld else { return }
            // The unit is settled before the notches are counted, so a slide
            // that goes up and across erases what the key now says it will.
            if latch.advance(translationY: translationY) {
                hasChangedUnit = true
                Haptics.play(.modeChange)
            }
            let steps = tracker.advance(translationX: translationX)
            guard !steps.isEmpty else { return }
            for step in steps {
                scrub(step.phase, granularity)
                // The tick is the whole point: it is how a thumb counts
                // characters off a screen it is not looking at.  Coming back
                // gets a softer thud, so the two directions are not one event
                // to the hand.
                Haptics.play(step == .delete ? .step : .release)
            }
        case .ended:
            finish(sendKey: !tracker.hasStepped && !hasChangedUnit)
        case .cancelled:
            finish(sendKey: false)
        }
    }

    private func finish(sendKey: Bool) {
        guard isHeld else { return }
        isHeld = false
        // The lift is also where the Mac erases anything it had to hold back,
        // so it arrives even for a tap that never slid.
        scrub(.end, granularity)
        if sendKey { send(hotkey) }
        IPhoneDebugLog.emit("delete_scrub", [
            "steps": "\(tracker.steps)",
            "slid": tracker.hasStepped ? "yes" : "no",
            "unit": latch.isWord ? "word" : "character"
        ])
        tracker = DeleteScrubTracker()
        // The key reports back to characters as soon as the finger lifts, so
        // the label never shows a mode from a press that already ended.
        latch.reset()
    }
}
#endif
