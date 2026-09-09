import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// One held press of the arrow pad, as far as the Mac's card is concerned.
///
/// The card only ever needs to know the key is down: the arrows themselves go
/// out as ordinary hotkeys, and the Mac lights whichever one it applied. So a
/// press is a single bit, and this is where the messages that carry it live,
/// apart from the key view so the whole of it can be tested without a touch.
public struct ArrowPadPress: Equatable, Sendable {
    /// True once the key has gone down, which is what a lift has to close.
    public private(set) var hasBegun = false

    public init() {}

    /// Touch-down. The card opens here, so it is on the Mac screen by the time
    /// the finger has travelled its first notch.
    public mutating func begin() -> ArrowPadPayload? {
        guard !hasBegun else { return nil }
        hasBegun = true
        return ArrowPadPayload(phase: .begin)
    }

    /// What the Mac is told again while the key is held but still. A finger
    /// resting between notches is silent, and the Mac closes a card that has
    /// gone quiet, so the press says it is still a press every couple of
    /// seconds.
    public var keepalive: ArrowPadPayload? {
        guard hasBegun else { return nil }
        return ArrowPadPayload(phase: .begin)
    }

    /// Lifting the finger, however it lifted. A press always closes the card
    /// it opened, and one that never opened has no card to close.
    public mutating func lift() -> ArrowPadPayload? {
        guard hasBegun else { return nil }
        self = ArrowPadPress()
        return ArrowPadPayload(phase: .end)
    }
}
#endif
