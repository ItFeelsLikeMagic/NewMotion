#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// A delete key that is also a dial.  A tap sends the key it always sent.
/// Holding it and sliding left rubs out one notch of text at a time, with a
/// tick for each; sliding back brings those characters back.  Both delete keys
/// are this view, so what one notch removes is the only difference between
/// them.
///
/// A tap still costs exactly one message: the press says nothing until the
/// finger actually moves.
struct DeleteScrubKey<Label: View>: View {
    let hotkey: RemoteHotkey
    let granularity: DeleteScrubGranularity
    let send: (RemoteHotkey) -> Void
    let scrub: (DeleteScrubPhase, DeleteScrubGranularity) -> Void
    let label: Label

    @State private var tracker = DeleteScrubTracker()
    @State private var isHeld = false
    @State private var hasBegun = false

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
                spokenName: "\(hotkey.spokenName). Hold and slide left to erase, right to undo.",
                onPhase: handle
            )
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
            hasBegun = false
            tracker = DeleteScrubTracker()
            Haptics.play(.press)
        case let .moved(translationX, _):
            guard isHeld else { return }
            let steps = tracker.advance(translationX: translationX)
            guard !steps.isEmpty else { return }
            beginIfNeeded()
            for step in steps {
                scrub(step.phase, granularity)
                // The tick is the whole point: it is how a thumb counts
                // characters off a screen it is not looking at.  Coming back
                // gets a softer thud, so the two directions are not one event
                // to the hand.
                Haptics.play(step == .delete ? .step : .release)
            }
        case .ended:
            finish(sendKey: !tracker.hasStepped)
        case .cancelled:
            finish(sendKey: false)
        }
    }

    /// The Mac only needs to know a press is under way once it is about to be
    /// asked to erase something, which is also when it should start waking the
    /// focused field.
    private func beginIfNeeded() {
        guard !hasBegun else { return }
        hasBegun = true
        scrub(.begin, granularity)
    }

    private func finish(sendKey: Bool) {
        guard isHeld else { return }
        isHeld = false
        if hasBegun { scrub(.end, granularity) }
        hasBegun = false
        if sendKey { send(hotkey) }
        IPhoneDebugLog.emit("delete_scrub", [
            "steps": "\(tracker.steps)",
            "slid": tracker.hasStepped ? "yes" : "no"
        ])
        tracker = DeleteScrubTracker()
    }
}
#endif
