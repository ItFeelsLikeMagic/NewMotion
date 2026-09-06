import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Every latency probe the phone keeps, in one place, so no stage on the
/// cursor or voice path has to know about the debug log.
///
/// Recording costs a clock read and one uncontended lock.  Sorting and
/// formatting happen only in `emitSummary`, on the five-second timer.
enum PhoneLatency {
    /// Cursor, click and voice traffic through Core Bluetooth.
    static let linkSendData = LatencyTracker(name: "link.send.data")
    /// Handshake traffic, kept apart so a slow pairing cannot be read as a
    /// slow cursor.
    static let linkSendControl = LatencyTracker(name: "link.send.control")
    /// Seal plus wire for one input message.  Subtract `link.send.data` from
    /// this and what is left is the phone's own sealing cost.
    static let inputToWire = LatencyTracker(name: "input.gesture->wire")
    /// How long accumulated travel sat waiting on a busy link before it went
    /// out.  This is the lag the hand feels.
    static let inputHeld = LatencyTracker(name: "input.held")
    /// Phone to Mac and back, sampled every couple of seconds.
    static let roundTrip = LatencyTracker(name: "link.rtt")

    /// The log key is kept short and separate from the tracker name so the
    /// name stays free to read.
    private static let all: [(key: String, tracker: LatencyTracker)] = [
        ("linkData", linkSendData),
        ("linkCtrl", linkSendControl),
        ("input", inputToWire),
        ("held", inputHeld),
        ("rtt", roundTrip)
    ]

    /// Picks a tracker without allocating, so `send` can call it inline.
    static func linkSend(on channel: LinkChannel) -> LatencyTracker {
        switch channel {
        case .data: return linkSendData
        case .control: return linkSendControl
        }
    }

    /// One line per stage as a single event.  Per-sample lines would flood the
    /// log and slow the very path being measured.  Timings are a rolling
    /// window; `refused=` and the attempt count are running totals, so the
    /// recent refusal rate is the difference between two of these lines.
    static func emitSummary(link: String) {
        var fields = ["link": link]
        for (key, tracker) in all {
            guard let summary = tracker.summary() else { continue }
            fields[key] = summary.line
        }
        guard fields.count > 1 else { return }
        IPhoneDebugLog.emit("latency", fields)
    }
}

extension LatencyTracker {
    /// A send that got through is a timing; anything else is a refusal.  The
    /// refusals are the point: a link falling behind shows flat timings and a
    /// climbing refusal rate.
    func record(_ clock: LatencyClock, sent: Bool) {
        if sent {
            record(microseconds: clock.elapsedMicroseconds)
        } else {
            recordRefusal()
        }
    }
}
