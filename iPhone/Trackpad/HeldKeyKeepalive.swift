#if canImport(SwiftUI) && os(iOS)
import Foundation

/// The heartbeat that keeps the Mac's card open while a key is held.
///
/// The Mac closes a card that has gone quiet, because a phone that suspends
/// mid-press sends no lift and would otherwise leave the card up.  A thumb
/// resting between notches is quiet too, so what the card is showing is said
/// again on a timer.  It lives here rather than on the model because a
/// published write every two seconds would rebuild the screen under the
/// finger, and it holds the payload rather than the press so the block sends
/// what is true now, not what was true when it was scheduled.
@MainActor
final class HeldKeyKeepalive<Payload: Sendable> {
    /// Three of these fit inside the Mac's silence timeout, so it takes three
    /// missed heartbeats, not one, to close a card someone is still using.
    static var interval: TimeInterval { 2 }

    private var timer: Timer?
    private var payload: Payload?
    private var send: ((Payload) -> Void)?

    func start(_ payload: Payload?, send: @escaping (Payload) -> Void) {
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

    func update(_ payload: Payload?) {
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
