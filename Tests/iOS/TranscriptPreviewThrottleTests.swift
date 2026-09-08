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
    /// nothing it is not already showing.
    func testARepeatedPartialIsNotSent() {
        var throttle = TranscriptPreviewThrottle()

        XCTAssertEqual(throttle.partial("hello", at: 0), "hello")
        XCTAssertNil(throttle.partial("hello", at: 1))
        XCTAssertNil(throttle.partial("  hello \n", at: 2))
        XCTAssertEqual(throttle.sentCount, 1)
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
