import CryptoKit
import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// What the phone lets through to the Mac's card while someone is still
/// talking. Apple's analyser revises a partial many times a second, and every
/// one of them shares the link with the typing it is previewing.
final class TranscriptPreviewThrottleTests: XCTestCase {
    func testTheFirstPartialGoesStraightOut() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("hello", at: 0), "hello")
        XCTAssertEqual(throttle.sentCount, 1)
    }

    /// The analyser repeats itself between words, and a repeat tells the card
    /// nothing it is not already showing, until the Mac's idle clear is close.
    func testARepeatedPartialIsNotSent() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("hello", at: 0), "hello")
        XCTAssertNil(throttle.partial("hello", at: 0.3))
        XCTAssertNil(throttle.partial("  hello \n", at: 0.6))
        XCTAssertEqual(throttle.sentCount, 1)
    }

    /// Someone pausing mid-sentence sends nothing new, and the Mac wipes its
    /// card after two silent seconds. So the same words go out again, once a
    /// second, and the words stay up until the talk button is let go.
    func testUnchangedWordsGoOutAgainAfterASecond() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("hello", at: 0), "hello")
        XCTAssertEqual(throttle.partial("hello", at: 1), "hello")
        XCTAssertEqual(throttle.partial("  hello \n", at: 2), "hello")
        XCTAssertEqual(throttle.sentCount, 3)
    }

    /// Halfway through the pause the card is in no danger, so the repeat is
    /// still not worth the wire.
    func testUnchangedWordsAreNotResentHalfwayThroughThePause() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("hello", at: 0), "hello")
        XCTAssertNil(throttle.partial("hello", at: 0.5))
        XCTAssertNil(throttle.partial("hello", at: 0.99))
        XCTAssertEqual(throttle.partial("hello", at: 1.0), "hello")
        XCTAssertEqual(throttle.sentCount, 2)
    }

    /// A pause before any words means there is nothing to keep alive, and an
    /// empty message is the one that clears the card.
    func testAnEmptyPreviewIsNeverKeptAlive() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertNil(throttle.partial("", at: 0))
        XCTAssertNil(throttle.partial("", at: 5))
        XCTAssertEqual(throttle.sentCount, 0)
    }

    func testNoMoreThanTenASecond() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("one", at: 0), "one")
        XCTAssertNil(throttle.partial("one two", at: 0.05))
        XCTAssertNil(throttle.partial("one two three", at: 0.099))
        XCTAssertEqual(throttle.partial("one two three four", at: 0.1), "one two three four")
        XCTAssertEqual(throttle.sentCount, 2)
    }

    /// A revision held back must not be mistaken for one already on the card,
    /// so the next partial after the wait still goes out.
    func testAHeldBackRevisionIsNotRecordedAsSent() {
        var throttle = TranscriptPreviewThrottle()

        _ = throttle.partial("one", at: 0)
        XCTAssertNil(throttle.partial("one two", at: 0.05))
        XCTAssertEqual(throttle.partial("one two", at: 0.2), "one two")
    }

    /// The card only ever shows the end of a sentence, so a long one is cut
    /// down to the last words that fit the wire's cap.
    func testALongPreviewKeepsOnlyItsTail() throws {
        var throttle = TranscriptPreviewThrottle()
        let words = Array(repeating: "chatter", count: 80).joined(separator: " ")

        let sent = try XCTUnwrap(throttle.partial(words, at: 0))
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

    /// The end of an utterance clears the card once, and only when there is
    /// something on it.
    func testClearingIsAskedForOnlyWhenSomethingWasSent() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertFalse(throttle.clear())
        _ = throttle.partial("hello", at: 0)
        XCTAssertTrue(throttle.clear())
        XCTAssertFalse(throttle.clear())
    }

    /// The next utterance starts from nothing, so the same words spoken twice
    /// are shown twice.
    func testClearingStartsTheNextUtteranceFresh() {
        var throttle = TranscriptPreviewThrottle()

        _ = throttle.partial("hello", at: 0)
        _ = throttle.clear()
        XCTAssertEqual(throttle.partial("hello", at: 0.01), "hello")
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
        let mac = MacHandshakePeer()
        let model = NewMotionFeatureModel(
            link: link,
            pairingCoordinator: try mac.trustedCoordinator(),
            uptime: { clock.value }
        )
        try await mac.authenticate(model: model, link: link)

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

    /// A tick inside the second is the analyser's own repeat rate, and it must
    /// not turn into traffic.
    func testTicksInsideTheSecondSendNothing() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let mac = MacHandshakePeer()
        let model = NewMotionFeatureModel(
            link: link,
            pairingCoordinator: try mac.trustedCoordinator(),
            uptime: { clock.value }
        )
        try await mac.authenticate(model: model, link: link)

        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        let afterFirstPartial = link.dataMessageCount

        clock.value += 0.5
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, afterFirstPartial)
    }

    /// The utterance ending stops the tick, so a phone sitting idle is not
    /// repeating the last thing anyone said.
    func testTheTickStopsWhenTheUtteranceEnds() async throws {
        let clock = PreviewClock(1_000)
        let link = FakeMessageLink()
        let mac = MacHandshakePeer()
        let model = NewMotionFeatureModel(
            link: link,
            pairingCoordinator: try mac.trustedCoordinator(),
            uptime: { clock.value }
        )
        try await mac.authenticate(model: model, link: link)

        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        model.onDeviceVoice.onUtteranceFinished?()
        try await settle()
        let afterClear = link.dataMessageCount

        clock.value += 5
        model.keepVoicePreviewAlive()
        XCTAssertEqual(link.dataMessageCount, afterClear)
    }

    /// The model answers its recogniser and its link through a main-actor hop.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }
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
