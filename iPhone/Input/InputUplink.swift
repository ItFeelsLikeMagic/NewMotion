import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Turns remote input into link messages.  It owns the travel the link has not
/// taken yet, the rule that a click never overtakes the travel before it, and
/// the retry once a busy link frees up.  It knows nothing about Bluetooth: swap
/// the `InputLink` under it and this stage does not change.
@MainActor
final class InputUplink {
    /// One beat, in milliseconds, matching the field the heartbeat carries.
    /// The Mac waits several of these before it releases, so a beat lost to a
    /// busy link costs nothing.  Beating faster only buys airtime.
    static let heartbeatIntervalMs: UInt16 = 250

    private let link: InputLink
    private var pointerTravel = CursorTravel()
    private var scrollTravel = CursorTravel()
    private var held = HeldRemoteInput()
    /// Runs only while something is held, so an idle remote is silent.
    private var heartbeatTimer: Timer?
    /// Set when travel first found the link busy, cleared when it finally goes
    /// out.  A growing hold is the lag the hand feels.
    private var travelHeldSince: LatencyClock?

    init(link: InputLink) {
        self.link = link
        link.onReadyToSend = { [weak self] in
            MainActor.assumeIsolated { self?.flushTravel() }
        }
    }

    var isReady: Bool { link.isReady }

    /// What the Mac is currently being asked to hold down.  Read by the debug
    /// surface; the heartbeat is what the Mac actually acts on.
    var heldInput: HeldRemoteInput { held }

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
            defer { syncHeartbeat() }
            do {
                for payload in try SharedTrackpadProtocolAdapter.payloads(for: event) {
                    guard deliver(payload) else { return false }
                }
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    func send(_ payload: MessagePayload) -> Bool {
        defer { syncHeartbeat() }
        return deliver(payload)
    }

    /// A preview never queues, for the same reason a beat does not: ten a
    /// second on the ordered path would sit ahead of the very typing they are
    /// previewing, and a partial that arrives late is worth less than the one
    /// behind it.  It holds nothing down either, so it stays out of the held
    /// set, and out of the latency window where an expected refusal would bury
    /// a real one.
    @discardableResult
    func sendTranscriptPreview(_ payload: TranscriptPreviewPayload) -> Bool {
        link.send(.payload(.transcriptPreview(payload)), delivery: .latestWins) == .sent
    }

    /// Puts one message on the link and folds it into the held set.  The beat
    /// is settled by the caller, once, after the whole event has gone out: a
    /// click is a press and a release together, and nothing is held in between.
    @discardableResult
    private func deliver(_ payload: MessagePayload) -> Bool {
        let clock = LatencyClock()
        let result = link.send(.payload(payload), delivery: .ordered)
        PhoneLatency.inputToWire.record(clock, sent: result == .sent)
        guard result == .sent else { return false }
        // Only a message that reached the link counts as held.  Recording one
        // that did not would make the next heartbeat press it down on the Mac,
        // because reconcile repairs a difference in either direction.
        held.record(payload)
        return true
    }

    /// Starts the beat when something is being held and stops it when nothing
    /// is.  The Mac arms its watchdog on the first beat, so a remote that
    /// never holds anything never arms anything either.
    private func syncHeartbeat() {
        guard !held.isEmpty else {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            return
        }
        guard heartbeatTimer == nil else { return }
        sendHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Double(Self.heartbeatIntervalMs) / 1_000,
            repeats: true
        ) { [weak self] timer in
            let stillOwned = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.sendHeartbeat()
                return true
            }
            // The run loop holds a repeating timer even when nothing else
            // does, so an owner that went away has to stop it from here.
            if !stillOwned { timer.invalidate() }
        }
    }

    /// A beat never queues.  A stale one is worth nothing, and holding up the
    /// ordered path four times a second would delay real input.  A skipped
    /// beat is what the Mac's patience is sized for, which is also why the
    /// beat stays out of the latency window: counting an expected refusal
    /// there would bury a real one.
    private func sendHeartbeat() {
        _ = link.send(
            .payload(.heartbeat(held.heartbeat(intervalMs: Self.heartbeatIntervalMs))),
            delivery: .latestWins
        )
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
        let clock = LatencyClock()
        let result = link.send(.compact(body: body, type: .pointerDelta), delivery: ordered ? .ordered : .latestWins)
        PhoneLatency.inputToWire.record(clock, sent: result == .sent)
        switch result {
        case .sent:
            if let heldSince = travelHeldSince {
                PhoneLatency.inputHeld.record(microseconds: heldSince.elapsedMicroseconds)
                travelHeldSince = nil
            }
            // Subtract what went out rather than zeroing, so the sub-point
            // remainder and any travel past the wire limit survive.
            pointerTravel.take(x: pointer.x, y: pointer.y)
            scrollTravel.take(x: scroll.x, y: scroll.y)
        case .busy:
            // The first refusal starts the clock; later ones are the same wait
            // still running.
            if travelHeldSince == nil { travelHeldSince = LatencyClock() }
        case .unavailable:
            reset()
        }
    }

    /// Called when the link has gone.  Nothing can be released over a link
    /// that is not there, and the Mac releases everything it holds when the
    /// session drops, so the held set is dropped rather than drained.
    func reset() {
        travelHeldSince = nil
        pointerTravel.clear()
        scrollTravel.clear()
        held.clear()
        syncHeartbeat()
    }
}
