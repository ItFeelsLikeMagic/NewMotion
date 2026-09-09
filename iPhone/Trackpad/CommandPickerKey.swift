#if canImport(SwiftUI) && os(iOS)
import Foundation
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The Command key that is also a menu.  Hold it and slide, and a card on the
/// Mac lights its way across the shared grid of shortcuts; lift, and the Mac
/// fires the lit one.  The Mac holds nothing down while it lasts, so a press
/// that never ends leaves nothing stuck.
///
/// Like the delete keys, the press announces itself the moment the key goes
/// down, so the card is already up by the time the finger starts to move.  It
/// opens on the grid's Cancel cell, so a stray tap costs one message and still
/// fires nothing.
struct CommandPickerKey: View {
    let picker: (KeyPickerPhase, HotkeyAction?) -> Void

    /// Wider notches than the other held keys: a cell of the grid is a
    /// choice, not a character, so a longer slide per cell buys precision at
    /// the cost of travel.
    private static let slideSensitivity = 0.6
    @State private var tracker = SlideStepTracker(sensitivity: Self.slideSensitivity)
    @State private var press = KeyPickerPress()
    @State private var isHeld = false
    @State private var keepalive = KeyPickerKeepalive()
    /// The lit cell's name, kept here rather than on the model: the model is
    /// published, and a write per notch would rebuild the screen under the
    /// finger that is still sliding.
    @State private var litName = ""

    var body: some View {
        Text("⌘")
            .heldKeyStyle(isHeld: isHeld)
            // The name is always in the tree and only fades, because swapping
            // it in and out rebuilds the surface below: the removed view
            // leaves the window, which reads as a cancelled press, and the
            // slide dies after its first notch.
            .overlay(alignment: .bottom) { name }
            .holdSlide(
                "key_picker",
                spokenName: "Command shortcuts. Hold and slide to choose.",
                onPhase: handle
            )
            // A key that leaves the screen mid-press takes its heartbeat with
            // it; the Mac's silence timeout then closes the card on its own.
            .onDisappear { keepalive.stop() }
    }

    /// The phone's own copy of what is lit.  The Mac's card is the display
    /// this gesture is aimed at, but it must not be the only one.
    private var name: some View {
        Text(litName)
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 3)
            .background(Color.black.opacity(0.35), in: Capsule())
            .padding(2)
            .opacity(litName.isEmpty ? 0 : 1)
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            guard !isHeld else { return }
            isHeld = true
            tracker = SlideStepTracker(sensitivity: Self.slideSensitivity)
            press = KeyPickerPress()
            if let message = press.begin() { picker(message.phase, message.cell) }
            // Cancel is lit from the word go, so the label says so from the
            // word go too.
            litName = KeyPickerGrid.displayName(for: press.cell) ?? ""
            keepalive.start(press.keepalive) { picker($0.phase, $0.cell) }
            Haptics.play(.press)
        case let .moved(translationX, translationY):
            guard isHeld else { return }
            for step in tracker.advance(translationX: translationX, translationY: translationY) {
                let messages = press.notch(step)
                guard !messages.isEmpty else { continue }
                for message in messages { picker(message.phase, message.cell) }
                litName = KeyPickerGrid.displayName(for: press.cell) ?? ""
                keepalive.update(press.keepalive)
                // The thump is how a thumb counts cells off a screen it is not
                // looking at, so it has to be felt over the slide itself.
                Haptics.play(.pickerStep)
            }
        case .ended:
            finish(committing: true)
        case .cancelled:
            finish(committing: false)
        }
    }

    /// Every press closes the card it opened.  A commit lifted on Cancel fires
    /// nothing, which is what keeps a stray tap on this key harmless.
    private func finish(committing: Bool) {
        guard isHeld else { return }
        isHeld = false
        keepalive.stop()
        if let message = press.lift(committing: committing) {
            picker(message.phase, message.cell)
            Haptics.play(.release)
            IPhoneDebugLog.emit("key_picker", ["end": committing ? "commit" : "cancel"])
        }
        tracker = SlideStepTracker(sensitivity: Self.slideSensitivity)
        litName = ""
    }
}

/// The heartbeat that keeps the Mac's card open while the key is held.
///
/// The Mac closes a picker that has gone quiet, because a phone that suspends
/// mid-press sends no lift and would otherwise leave the card up and the
/// cursor frozen.  A thumb resting on a cell is quiet too, so the lit cell is
/// said again on a timer.  It lives here rather than on the model because a
/// published write every two seconds would rebuild the screen under the
/// finger, and it holds the payload rather than the press so the block sends
/// the cell that is lit now, not the one lit when it was scheduled.
@MainActor
final class KeyPickerKeepalive {
    /// Three of these fit inside the Mac's silence timeout, so it takes three
    /// missed heartbeats, not one, to close a card someone is still using.
    static let interval: TimeInterval = 2

    private var timer: Timer?
    private var payload: KeyPickerPayload?
    private var send: ((KeyPickerPayload) -> Void)?

    func start(_ payload: KeyPickerPayload?, send: @escaping (KeyPickerPayload) -> Void) {
        stop()
        self.payload = payload
        self.send = send
        // `.common` mode on purpose: the run loop tracks a touch in its own
        // mode, and this beats while a finger is very much down.
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.tolerance = Self.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(_ payload: KeyPickerPayload?) {
        self.payload = payload
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        payload = nil
        send = nil
    }

    private func beat() {
        guard let payload, let send else { return }
        send(payload)
    }
}
#endif
