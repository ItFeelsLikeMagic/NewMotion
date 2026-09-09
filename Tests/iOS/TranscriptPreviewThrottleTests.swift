import CryptoKit
import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// Deciding and recording are two calls, so the tests that are only about the
/// decision say so once here: they offer the words and take the send as having
/// reached the wire.
private extension TranscriptPreviewThrottle {
    mutating func sends(_ text: String, at now: Double) -> String? {
        guard case let .send(tail) = partial(text, at: now) else { return nil }
        sent(tail, at: now)
        return tail
    }
}

/// What the phone lets through to the Mac's card while someone is still
/// talking. Apple's analyser revises a partial many times a second, and every
/// one of them shares the link with the typing it is previewing.
final class TranscriptPreviewThrottleTests: XCTestCase {
    func testTheFirstPartialGoesStraightOut() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.sends("hello", at: 0), "hello")
        XCTAssertEqual(throttle.sentCount, 1)
    }

    /// The analyser repeats itself between words, and a repeat tells the card
    /// nothing it is not already showing, until the Mac's idle clear is close.
    func testARepeatedPartialIsNotSent() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.sends("hello", at: 0), "hello")
        XCTAssertNil(throttle.sends("hello", at: 0.2))
        XCTAssertNil(throttle.sends("  hello \n", at: 0.45))
        XCTAssertEqual(throttle.sentCount, 1)
    }

    /// Someone pausing mid-sentence sends nothing new, and the Mac wipes its
    /// card after two silent seconds. So the same words go out again, twice
    /// a second, and the words stay up until the talk button is let go.
    func testUnchangedWordsGoOutAgainAfterHalfASecond() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.sends("hello", at: 0), "hello")
        XCTAssertEqual(throttle.sends("hello", at: 0.5), "hello")
        XCTAssertEqual(throttle.sends("  hello \n", at: 1), "hello")
        XCTAssertEqual(throttle.sentCount, 3)
    }

    /// Halfway through the pause the card is in no danger, so the repeat is
    /// still not worth the wire.
    func testUnchangedWordsAreNotResentHalfwayThroughThePause() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.sends("hello", at: 0), "hello")
        XCTAssertNil(throttle.sends("hello", at: 0.25))
        XCTAssertNil(throttle.sends("hello", at: 0.49))
        XCTAssertEqual(throttle.sends("hello", at: 0.5), "hello")
        XCTAssertEqual(throttle.sentCount, 2)
    }

    /// The talk button going down offers no words at all, and that empty
    /// preview is the listening card: it goes out, and it is kept alive like
    /// any other, or the Mac's idle clear takes the card mid-hold.
    func testAnEmptyPreviewIsSentAndKeptAlive() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.sends("", at: 0), "")
        XCTAssertNil(throttle.sends("", at: 0.25))
        XCTAssertEqual(throttle.sends("", at: 0.5), "")
        XCTAssertEqual(throttle.sentCount, 2)
    }

    func testNoMoreThanTenASecond() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.sends("one", at: 0), "one")
        XCTAssertNil(throttle.sends("one two", at: 0.05))
        XCTAssertNil(throttle.sends("one two three", at: 0.099))
        XCTAssertEqual(throttle.sends("one two three four", at: 0.1), "one two three four")
        XCTAssertEqual(throttle.sentCount, 2)
    }

    /// A revision held back must not be mistaken for one already on the card,
    /// so the next partial after the wait still goes out.
    func testAHeldBackRevisionIsNotRecordedAsSent() {
        var throttle = TranscriptPreviewThrottle()

        _ = throttle.sends("one", at: 0)
        XCTAssertNil(throttle.sends("one two", at: 0.05))
        XCTAssertEqual(throttle.sends("one two", at: 0.2), "one two")
    }

    /// The card only ever shows the end of a sentence, so a long one is cut
    /// down to the last words that fit the wire's cap.
    func testALongPreviewKeepsOnlyItsTail() throws {
        var throttle = TranscriptPreviewThrottle()
        let words = Array(repeating: "chatter", count: 80).joined(separator: " ")

        let sent = try XCTUnwrap(throttle.sends(words, at: 0))
        XCTAssertLessThanOrEqual(sent.utf8.count, TranscriptPreviewPayload.maximumUTF8Bytes)
        XCTAssertTrue(words.hasSuffix(sent))
        XCTAssertTrue(sent.hasPrefix("chatter"))
        XCTAssertNoThrow(try TranscriptPreviewPayload(text: sent))
    }

    /// Cut on a space, so the card never opens on half a word.
    func testTheTailIsCutOnASpace() {
        let text = String(repeating: "ab ", count: 200) + "end"

        let tail = TranscriptPreviewThrottle.tail(of: text, maximumUTF8Bytes: 10)
        XCTAssertEqual(tail, "ab ab end")
    }

    /// One word longer than the whole cap has no space to cut at, and showing
    /// its end beats showing nothing.
    func testAWordLongerThanTheCapIsCutHard() {
        let tail = TranscriptPreviewThrottle.tail(of: String(repeating: "x", count: 40), maximumUTF8Bytes: 10)

        XCTAssertEqual(tail, String(repeating: "x", count: 10))
    }

    /// The cap is in bytes, not characters, so a sentence of wide characters
    /// still fits the field it is going into.
    func testTheCapCountsBytesRatherThanCharacters() {
        let tail = TranscriptPreviewThrottle.tail(of: String(repeating: "日", count: 40), maximumUTF8Bytes: 10)

        XCTAssertLessThanOrEqual(tail.utf8.count, 10)
        XCTAssertEqual(tail.count, 3)
    }

    /// The end of an utterance takes the card down once, and only when there
    /// is a card up.
    func testClearingIsAskedForOnlyWhenACardIsUp() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertFalse(throttle.clear())
        _ = throttle.sends("hello", at: 0)
        XCTAssertTrue(throttle.clear())
        XCTAssertFalse(throttle.clear())

        // A card with no words on it is still a card to take down.
        _ = throttle.sends("", at: 1)
        XCTAssertTrue(throttle.clear())
    }

    /// The next utterance starts from nothing, so the same words spoken twice
    /// are shown twice.
    func testClearingStartsTheNextUtteranceFresh() {
        var throttle = TranscriptPreviewThrottle()

        _ = throttle.sends("hello", at: 0)
        _ = throttle.clear()
        XCTAssertEqual(throttle.sends("hello", at: 0.01), "hello")
        XCTAssertEqual(throttle.sentCount, 1)
    }

    /// A revision held back is owed a message, and the wait is the rest of the
    /// window rather than the keepalive's whole second.
    func testWordsHeldBackAskForATrailingSend() {
        var throttle = TranscriptPreviewThrottle()

        _ = throttle.sends("one", at: 0)
        guard case let .tooSoon(after) = throttle.partial("one two", at: 0.04) else {
            return XCTFail("new words inside the window are owed a message")
        }
        XCTAssertEqual(after, 0.06, accuracy: 0.001)
    }

    /// The link refusing a message leaves the card showing the words before it,
    /// so the same words are still worth sending.
    func testARefusedSendIsOfferedAgain() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("one two", at: 0), .send("one two"))
        // Nothing recorded: the link said no.
        XCTAssertEqual(throttle.partial("one two", at: 0.2), .send("one two"))
        XCTAssertEqual(throttle.sentCount, 0)

        throttle.sent("one two", at: 0.2)
        XCTAssertEqual(throttle.partial("one two", at: 0.4), .nothing)
        XCTAssertEqual(throttle.sentCount, 1)
    }
}

/// The phone's own tick behind the throttle. Apple's analyser stops revising
/// while someone pauses mid-sentence, so without a tick nothing would call the
/// throttle at all and the Mac's idle clear would take the words away.
@MainActor
final class VoicePreviewKeepaliveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
        super.tearDown()
    }

    func testAPauseStillPutsTheWordsBackOnTheWire() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        let afterFirstPartial = link.dataMessageCount
        XCTAssertGreaterThan(afterFirstPartial, 0, "the first partial goes straight out")

        // The analyser says nothing more: they are pausing, finger still down.
        clock.value += 1
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, afterFirstPartial + 1)

        clock.value += 1
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, afterFirstPartial + 2)
    }

    /// A tick inside the interval is the analyser's own repeat rate, and it
    /// must not turn into traffic.
    func testTicksInsideTheIntervalSendNothing() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        let afterFirstPartial = link.dataMessageCount

        clock.value += 0.25
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, afterFirstPartial)
    }

    /// The card is the hint that the Mac is listening, so it goes up with the
    /// finger rather than with the first word.
    func testTheButtonGoingDownPutsAnEmptyPreviewOnTheWire() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        let before = link.dataMessageCount
        model.beginVoicePreview()
        XCTAssertEqual(link.dataMessageCount, before + 1, "the card goes up before a word is said")

        // Still nobody talking, and the Mac's idle clear is coming.
        clock.value += 1
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, before + 2)
    }

    /// The finger lifting is what takes the card down, and the tick goes with
    /// it so an idle phone is not repeating anything.
    func testTheButtonComingUpEndsTheHoldAndStopsTheTick() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.beginVoicePreview()
        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        let beforeRelease = link.dataMessageCount

        model.endVoicePreview()
        XCTAssertEqual(link.dataMessageCount, beforeRelease + 1, "the end of the hold goes out")

        clock.value += 5
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, beforeRelease + 1)
    }

    /// A phrase typed with the finger still down leaves the card up and blank:
    /// the next phrase is already being listened for.
    func testAPhraseFinishingMidHoldGoesBackToListening() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.beginVoicePreview()
        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        let beforeFinish = link.dataMessageCount

        model.onDeviceVoice.onUtteranceFinished?()
        try await settle()
        XCTAssertEqual(link.dataMessageCount, beforeFinish + 1, "the words are blanked, the card stays")

        clock.value += 1
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, beforeFinish + 2, "the tick is still holding the card up")
    }

    /// The utterance ending stops the tick, so a phone sitting idle is not
    /// repeating the last thing anyone said.
    func testTheTickStopsWhenTheUtteranceEnds() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        model.onDeviceVoice.onUtteranceFinished?()
        try await settle()
        let afterClear = link.dataMessageCount

        clock.value += 5
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, afterClear)
    }
}

/// The words a revision adds inside the throttle's window. The analyser often
/// goes quiet right after that last revision, so without a trailing send the
/// card shows those words a second late, or never when the utterance ends
/// first.
@MainActor
final class VoicePreviewTrailingSendTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
        super.tearDown()
    }

    func testWordsHeldBackCrossWhenTheWindowOpens() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.onDeviceVoice.onPartialText?("hello")
        try await settle()
        let afterFirstPartial = link.dataMessageCount

        // The last revision of the phrase, too soon after the one before it.
        clock.value += 0.04
        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        XCTAssertEqual(link.dataMessageCount, afterFirstPartial, "the window is still closed")

        // The wait is real time; the clock the throttle reads is the test's, so
        // it has to reach past the end of the window as well.
        clock.value += 0.07
        spinRunLoop(for: 0.2)
        XCTAssertEqual(
            link.dataMessageCount,
            afterFirstPartial + 1,
            "nothing else would have sent those words before the keepalive"
        )
    }

    /// Words waiting on the window belong to an utterance that is over, and
    /// the card is being cleared of them anyway.
    func testTheUtteranceEndingCancelsTheWait() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let model = try await pairedModel(link: link, clock: clock)

        model.onDeviceVoice.onPartialText?("hello")
        try await settle()

        clock.value += 0.04
        model.onDeviceVoice.onPartialText?("hello there")
        model.onDeviceVoice.onUtteranceFinished?()
        try await settle()
        let afterClear = link.dataMessageCount

        clock.value += 1
        spinRunLoop(for: 0.2)
        XCTAssertEqual(link.dataMessageCount, afterClear, "the wait went with the utterance")
    }
}

/// A phone that has finished a trusted reconnect, and so is willing to send,
/// on a clock the test moves by hand.
@MainActor
private func pairedModel(link: FakeMessageLink, clock: PreviewClock) async throws -> NewMotionFeatureModel {
    let mac = MacHandshakePeer()
    let model = NewMotionFeatureModel(
        link: link,
        pairingCoordinator: try mac.trustedCoordinator(),
        uptime: { clock.value }
    )
    try await mac.authenticate(model: model, link: link)
    return model
}

/// The model answers its recogniser and its link through a main-actor hop.
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(80))
}

/// A trailing send is a run-loop timer, and an async test's sleep leaves the
/// run loop parked, so the wait for one has to turn it over by hand.
@MainActor
private func spinRunLoop(for duration: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}

/// The Mac's half of a trusted reconnect, which is what it takes for the phone
/// to consider itself able to send anything at all.
private final class MacHandshakePeer {
    let deviceID = UUID()
    let identity = PairingIdentity()
    private var phone: IPhonePairingCoordinator?

    func trustedCoordinator() throws -> IPhonePairingCoordinator {
        let coordinator = try IPhonePairingCoordinator(store: InMemoryTrustedDeviceStore())
        _ = try coordinator.rememberPairedMac(
            deviceID: deviceID,
            displayName: "Trusted Mac",
            peerIdentityPublicKey: identity.publicKey
        )
        phone = coordinator
        return coordinator
    }

    @MainActor
    func authenticate(model: NewMotionFeatureModel, link: FakeMessageLink) async throws {
        link.state = .connected
        link.onStateChange?(.connected)
        try await Task.sleep(for: .milliseconds(80))

        let hello = try XCTUnwrap(link.controlMessages.first)
        let server = PairingHandshakeServer(
            mode: .trusted(
                deviceID: deviceID,
                peerIdentityPublicKey: try XCTUnwrap(phone).identity.publicKey
            ),
            identity: identity,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        link.onMessage?(.control, try server.accept(clientHelloData: hello).response)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.isPaired, "the phone has a session and can send")
    }
}

private final class PreviewClock {
    var value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
}
