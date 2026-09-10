import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// What the phone has asked the Mac to hold down and not yet released.
///
/// Most remote input completes itself: a click carries its own release, a
/// hotkey its own key-up.  A few things do not.  A drag holds the left button
/// for as long as a finger slides, and the app switcher holds Command for as
/// long as the walk lasts.  Those are the ones that can strand the Mac if the
/// releasing message never lands, so they are the ones counted here.
///
/// The set is folded from the messages actually sent rather than from the
/// gesture that caused them, so it cannot drift from what the Mac was told.
/// Teaching the remote to hold something new means adding a case to `record`
/// and nothing else: the heartbeat, the watchdog, and the Mac's reconcile all
/// work off this set already.
struct HeldRemoteInput: Equatable {
    private(set) var buttons = HeldButtons()
    private(set) var modifiers = HeldModifiers()

    var isEmpty: Bool { buttons.isEmpty && modifiers.isEmpty }

    /// Folds one message that reached the link into the held set.  Call it
    /// only for a message that was actually sent: a press recorded here but
    /// never delivered would be pressed down by the Mac on the next beat,
    /// because reconcile repairs the difference in both directions.
    mutating func record(_ payload: MessagePayload) {
        switch payload {
        case let .mouseButton(value):
            let button = HeldButtons(value.button)
            if value.isDown {
                buttons.insert(button)
            } else {
                buttons.remove(button)
            }
        case let .tabWalk(value):
            // The walk holds its modifier from the first step until it is
            // committed or cancelled; the steps between change nothing. A row
            // that holds nothing leaves nothing here to strand.
            switch value.phase {
            case .begin:
                insert(value.row)
            case .commit, .cancel:
                remove(value.row)
            case .swap:
                if let leaving = value.leaving { remove(leaving) }
                insert(value.row)
            case .next, .previous:
                break
            }
        case .pointerDelta, .scrollDelta, .motionPointerDelta, .mouseDoubleClick,
             .textInput, .spokenText, .hotkey, .deleteScrub, .heartbeat,
             .vocabulary, .keyPicker, .arrowPad, .transcriptPreview,
             .acknowledgement, .connectionStatus, .error, .ping, .pong:
            break
        }
    }

    private mutating func insert(_ row: TabWalkRow) {
        guard let modifier = row.heldModifier else { return }
        modifiers.insert(HeldModifiers(modifier))
    }

    private mutating func remove(_ row: TabWalkRow) {
        guard let modifier = row.heldModifier else { return }
        modifiers.remove(HeldModifiers(modifier))
    }

    /// Forgets everything without releasing it.  Only correct when the link is
    /// gone, which is itself the signal for the Mac to let go.
    mutating func clear() {
        buttons = HeldButtons()
        modifiers = HeldModifiers()
    }

    func heartbeat(intervalMs: UInt16) -> HeartbeatPayload {
        HeartbeatPayload(
            isActive: true,
            buttons: buttons,
            modifiers: modifiers,
            heartbeatIntervalMs: intervalMs
        )
    }
}
