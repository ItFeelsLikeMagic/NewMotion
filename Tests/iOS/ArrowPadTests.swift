import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The phone half of the arrow pad: the two messages that put the Mac's card
/// up and take it down again, and the heartbeat that keeps it there.
final class ArrowPadPressTests: XCTestCase {
    /// Touch-down opens the card, so the four keys are on the Mac screen
    /// before the finger has travelled its first notch.
    func testTheKeyGoingDownOpensTheCardOnce() {
        var press = ArrowPadPress()

        XCTAssertEqual(press.begin(), ArrowPadPayload(phase: .begin))
        XCTAssertTrue(press.hasBegun)
        // A second touch inside the same press says nothing: the card is up.
        XCTAssertNil(press.begin())
    }

    /// A press with no touch behind it has no card to close, and nothing to
    /// keep alive.
    func testALiftWithNoPressSaysNothing() {
        var press = ArrowPadPress()

        XCTAssertNil(press.lift())
        XCTAssertNil(press.keepalive)
    }

    /// The heartbeat is another `begin`, because the phone never learns which
    /// arrow the Mac applied: the card lights itself from the keys that land.
    func testTheHeartbeatRepeatsTheOpeningMessage() {
        var press = ArrowPadPress()
        _ = press.begin()

        XCTAssertEqual(press.keepalive, ArrowPadPayload(phase: .begin))
    }

    /// Every press closes the card it opened, and leaves nothing behind that a
    /// second lift could close again.
    func testTheLiftClosesTheCardExactlyOnce() {
        var press = ArrowPadPress()
        _ = press.begin()

        XCTAssertEqual(press.lift(), ArrowPadPayload(phase: .end))
        XCTAssertFalse(press.hasBegun)
        XCTAssertNil(press.lift())
        XCTAssertNil(press.keepalive)

        // And the key can be held again straight away.
        XCTAssertEqual(press.begin(), ArrowPadPayload(phase: .begin))
    }
}
