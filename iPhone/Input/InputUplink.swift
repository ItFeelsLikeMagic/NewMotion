import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// Turns remote input into link messages.  It owns the travel the link has not
/// taken yet, the rule that a click never overtakes the travel before it, and
/// the retry once a busy link frees up.  It knows nothing about Bluetooth: swap
/// the `InputLink` under it and this stage does not change.
@MainActor
final class InputUplink {
    private let link: InputLink
    private var pointerTravel = CursorTravel()
    private var scrollTravel = CursorTravel()

    init(link: InputLink) {
        self.link = link
        link.onReadyToSend = { [weak self] in
            MainActor.assumeIsolated { self?.flushTravel() }
        }
    }

    var isReady: Bool { link.isReady }

    /// Travel accumulates and leaves on the next flush.  Everything else goes
    /// out behind the travel that preceded it.
    @discardableResult
    func send(_ event: RemoteInputEvent) -> Bool {
        switch event {
        case let .pointer(delta):
            pointerTravel.add(x: delta.x, y: delta.y)
            flushTravel()
            return true
        case let .scroll(delta):
            scrollTravel.add(x: delta.x, y: delta.y)
            flushTravel()
            return true
        case .leftClick, .rightClick, .doubleClick, .dragBegan, .dragEnded, .missionControl, .appExpose:
            flushTravel(ordered: true)
            do {
                for payload in try SharedTrackpadProtocolAdapter.payloads(for: event) {
                    guard send(payload) else { return false }
                }
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    func send(_ payload: MessagePayload) -> Bool {
        link.send(.payload(payload), delivery: .ordered) == .sent
    }

    /// Sends the accumulated travel as one compact frame.  When the link has no
    /// room the sum is kept rather than dropped, so the cursor ends up where the
    /// hand is instead of undershooting and then catching up.  `ordered` queues
    /// the frame so whatever follows it cannot arrive first.
    func flushTravel(ordered: Bool = false) {
        var items: [PointerStreamItem] = []
        let pointer = pointerTravel.wholePoints
        if pointer.x != 0 || pointer.y != 0 {
            items.append(PointerStreamItem(kind: .pointer, deltaX: pointer.x, deltaY: pointer.y))
        }
        let scroll = scrollTravel.wholePoints
        if scroll.x != 0 || scroll.y != 0 {
            items.append(PointerStreamItem(kind: .scroll, deltaX: scroll.x, deltaY: scroll.y))
        }
        // Travel under half a point is not dropped; it stays pending and rides
        // out with a later frame once it adds up to a whole one.
        guard !items.isEmpty else { return }
        guard let body = try? PointerStreamFrame(items: items).encode() else {
            reset()
            return
        }
        switch link.send(.compact(body: body, type: .pointerDelta), delivery: ordered ? .ordered : .latestWins) {
        case .sent:
            // Subtract what went out rather than zeroing, so the sub-point
            // remainder and any travel past the wire limit survive.
            pointerTravel.take(x: pointer.x, y: pointer.y)
            scrollTravel.take(x: scroll.x, y: scroll.y)
        case .busy:
            break
        case .unavailable:
            reset()
        }
    }

    func reset() {
        pointerTravel.clear()
        scrollTravel.clear()
    }
}
