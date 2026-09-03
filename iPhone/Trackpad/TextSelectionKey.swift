#if canImport(SwiftUI) && os(iOS)
import SwiftUI

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

public extension SlideStep {
    var selectionHotkey: RemoteHotkey {
        switch self {
        case .left: return .selectLeft
        case .right: return .selectRight
        case .up: return .selectUp
        case .down: return .selectDown
        }
    }
}

/// Hold and drag to select.  Sideways takes characters, up and down takes
/// lines, and every notch ticks so a thumb can count them off a screen it is
/// not looking at.
///
/// It is the delete keys' gesture without their memory: each notch is one
/// Shift and arrow, and the arrow the other way undoes it, so there is nothing
/// for the Mac to hold on to and nothing a tap could usefully do.
struct TextSelectionKey: View {
    let send: (RemoteHotkey) -> Void

    @State private var tracker = SlideStepTracker()
    @State private var isHeld = false

    var body: some View {
        Image(systemName: "character.cursor.ibeam")
            .heldKeyStyle(isHeld: isHeld)
            .holdSlide("text_selection", spokenName: "Select. Hold and drag to select text.", onPhase: handle)
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
                send(step.selectionHotkey)
                // The tick is how the hand counts what it has picked up.
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
