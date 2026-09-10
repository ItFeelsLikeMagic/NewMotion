import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The boost list handed to Apple's recogniser. It is the Mac's walk of its
/// own screen, so it can arrive long and can name the same thing twice.
final class VoiceBoostWordsTests: XCTestCase {
    func testKeepsTheMacsOrder() {
        XCTAssertEqual(
            VoiceBoostWords.limited(["Testaflight", "Ollama", "Xcode"]),
            ["Testaflight", "Ollama", "Xcode"]
        )
    }

    func testKeepsTheFirstSpellingOfARepeatedPhrase() {
        XCTAssertEqual(
            VoiceBoostWords.limited(["Testaflight", "testaflight", "TESTAFLIGHT", "Ollama"]),
            ["Testaflight", "Ollama"]
        )
    }

    func testKeepsMultiWordPhrasesWhole() {
        XCTAssertEqual(
            VoiceBoostWords.limited(["NewMotion", "air mouse"]),
            ["NewMotion", "air mouse"]
        )
    }

    func testEmptyScreenYieldsNoPhrases() {
        XCTAssertEqual(VoiceBoostWords.limited([]), [])
    }

    /// The recogniser is given a bounded list, so a screen full of text cannot
    /// turn one press into an unbounded context.
    func testStopsAtTheMaximum() {
        let seen = (0..<(VoiceBoostWords.maximumPhrases + 50)).map { "word\($0)" }
        let kept = VoiceBoostWords.limited(seen)
        XCTAssertEqual(kept.count, VoiceBoostWords.maximumPhrases)
        XCTAssertEqual(kept.first, "word0")
    }
}

/// The facade must be safe to hold and call on any OS the app runs on, even
/// where Apple's analyser does not exist.
final class OnDeviceVoiceTests: XCTestCase {
    func testReportsUnsupportedRatherThanFailingBelowItsMinimum() {
        let voice = OnDeviceVoice()
        if #available(iOS 26.0, *) {
            XCTAssertTrue(voice.isSupported)
        } else {
            XCTAssertFalse(voice.isSupported)
        }
    }

    func testCallsOutsideAnUtteranceAreIgnored() {
        let voice = OnDeviceVoice()
        let delivered = expectation(description: "no text is delivered")
        delivered.isInverted = true
        voice.onText = { _ in delivered.fulfill() }
        voice.append([0, 1, 2])
        voice.end()
        voice.cancel()
        wait(for: [delivered], timeout: 0.5)
    }

    func testUnsupportedReadinessHasAPlainLabel() {
        XCTAssertEqual(OnDeviceVoiceReadiness.unsupported.label, "Not available on this iPhone")
        XCTAssertEqual(OnDeviceVoiceReadiness.ready.label, "Ready")
    }
}

/// An utterance can end having produced no words at all, and until it says so
/// nothing takes back the preview it left behind.
@MainActor
final class VoicePreviewEndTests: XCTestCase {
    /// The same clear that empties the banner is the one that empties the
    /// throttle and owes the Mac its empty message, so a silent utterance
    /// leaving the banner up means the next one's opening partial would be
    /// swallowed as a repeat.
    func testAnUtteranceThatProducedNoTextStillEndsThePreview() async throws {
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(
            link: link,
            pairingCoordinator: try IPhonePairingCoordinator(store: InMemoryTrustedDeviceStore())
        )

        model.onDeviceVoice.onPartialText?("hello there")
        try await settle()
        XCTAssertEqual(model.voicePreview, "hello there")

        // No `onText`: the analyser settled without a sentence.
        model.onDeviceVoice.onUtteranceFinished?()
        try await settle()
        XCTAssertEqual(model.voicePreview, "")
    }

    /// The model answers its recogniser through a main-actor hop.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }
}

final class SpokenTextChunkerTests: XCTestCase {
    func testShortSentenceIsOnePiece() {
        XCTAssertEqual(SpokenTextChunker.split("hello there"), ["hello there"])
    }

    func testBlankInputYieldsNothingToSend() {
        XCTAssertEqual(SpokenTextChunker.split("   \n "), [])
        XCTAssertEqual(SpokenTextChunker.split(""), [])
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(SpokenTextChunker.split("  hello  "), ["hello"])
    }

    func testLongDictationIsSplitAndLosesNothing() {
        let long = String(repeating: "word ", count: 800)
        let pieces = SpokenTextChunker.split(long)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.utf8.count, SpokenTextChunker.maximumPieceUTF8Bytes)
        }
        XCTAssertEqual(pieces.joined(), long.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The Mac credits the word cache from the text it receives, one message
    /// at a time, so a word cut across two of them is credited to neither.
    func testSplitCutsBetweenWordsSoNoWordIsLostToTheCache() {
        let long = (0..<400).map { "Testaflight\($0)" }.joined(separator: " ")
        let pieces = SpokenTextChunker.split(long)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), long)
        // Every word in the original survives whole inside some one piece.
        let words = Set(long.split(separator: " ").map(String.init))
        let carried = Set(pieces.flatMap { $0.split(separator: " ").map(String.init) })
        XCTAssertEqual(words.subtracting(carried), [])
    }

    /// One word longer than a whole piece has no space to cut at, and arriving
    /// in halves beats not arriving.
    func testAWordLongerThanAPieceIsStillSent() {
        let monster = String(repeating: "a", count: SpokenTextChunker.maximumPieceUTF8Bytes * 2 + 7)
        let pieces = SpokenTextChunker.split(monster)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.joined(), monster)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.utf8.count, SpokenTextChunker.maximumPieceUTF8Bytes)
        }
    }

    /// A piece must never end halfway through a grapheme cluster, or the Mac
    /// types a replacement character where an emoji was.
    func testSplitKeepsGraphemeClustersWhole() {
        let long = String(repeating: "👩‍👩‍👧‍👦", count: 200)
        let pieces = SpokenTextChunker.split(long)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), long)
        for piece in pieces {
            XCTAssertFalse(piece.unicodeScalars.contains("\u{FFFD}"))
            XCTAssertLessThanOrEqual(piece.utf8.count, SpokenTextChunker.maximumPieceUTF8Bytes)
        }
    }
}
