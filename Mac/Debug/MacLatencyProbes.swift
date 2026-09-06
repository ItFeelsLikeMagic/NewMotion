import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// Every stage of the Mac's own path, timed continuously.
///
/// The trackers are handed to the parts that do the work rather than reached
/// through a global, so a test can watch one stage without the rest existing.
/// Recording costs a clock read and an uncontended lock; the sorting and the
/// formatting happen only when `/state` is read.
public final class MacLatencyProbes: Sendable {
    /// A message arriving from the phone to the input event leaving for the
    /// window server. The one number that says whether the Mac is the slow
    /// part, because no phone clock is involved in it.
    public let receiveToInject = LatencyTracker(name: "receiveToInject")
    /// Unsealing the message. The three stages below add up to
    /// `receiveToInject`, so a regression can be pinned to one of them.
    public let decrypt = LatencyTracker(name: "decrypt")
    public let decode = LatencyTracker(name: "decode")
    /// The protocol adapter plus the hand-off to `SafeInputInjector`.
    public let dispatch = LatencyTracker(name: "dispatch")
    /// One paced key burst, from hand-off to the last event posted.
    public let keyPost = LatencyTracker(name: "keyPost")
    /// Sends towards the phone. Refusals here mean a backed-up write queue,
    /// which shows as a rising refusal rate while the timings stay flat.
    public let linkSend = LatencyTracker(name: "linkSend")

    public init() {}

    /// Ordered headline first, then its parts, then the stages that stand on
    /// their own. A stage that has never run is left out rather than reported
    /// as zero.
    public func summaries() -> [LatencySummary] {
        [receiveToInject, decrypt, decode, dispatch, keyPost, linkSend]
            .compactMap { $0.summary() }
    }
}
