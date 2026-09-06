import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

/// The boost list the Settings field feeds to Apple's recogniser. Whatever is
/// typed there is a person's rough notes, so parsing has to survive stray
/// commas, blank lines, and the same name entered twice.
final class VoiceBoostWordsTests: XCTestCase {
    func testSplitsOnCommasAndNewlines() {
        XCTAssertEqual(
            VoiceBoostWords.parse("Testaflight, Ollama\nXcode"),
            ["Testaflight", "Ollama", "Xcode"]
        )
    }

    func testTrimsSpacesAndDropsEmptyEntries() {
        XCTAssertEqual(
            VoiceBoostWords.parse("  Testaflight ,, \n , Ollama  \n\n"),
            ["Testaflight", "Ollama"]
        )
    }

    func testKeepsTheFirstSpellingOfARepeatedPhrase() {
        XCTAssertEqual(
            VoiceBoostWords.parse("Testaflight, testaflight, TESTAFLIGHT, Ollama"),
            ["Testaflight", "Ollama"]
        )
    }

    func testKeepsMultiWordPhrasesWhole() {
        XCTAssertEqual(
            VoiceBoostWords.parse("Phone Remote, air mouse"),
            ["Phone Remote", "air mouse"]
        )
    }

    func testEmptyFieldYieldsNoPhrases() {
        XCTAssertEqual(VoiceBoostWords.parse(""), [])
        XCTAssertEqual(VoiceBoostWords.parse("   \n , , "), [])
    }

    /// The recogniser is given a bounded list, so a pasted document cannot
    /// turn one press into an unbounded context.
    func testStopsAtTheMaximum() {
        let raw = (0..<(VoiceBoostWords.maximumPhrases + 50))
            .map { "word\($0)" }
            .joined(separator: ",")
        let parsed = VoiceBoostWords.parse(raw)
        XCTAssertEqual(parsed.count, VoiceBoostWords.maximumPhrases)
        XCTAssertEqual(parsed.first, "word0")
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

/// The Mac's screen words and the owner's typed words become one list, and a
/// finished sentence has to fit the wire.
final class VoiceBoostMergeTests: XCTestCase {
    func testTypedWordsComeFirstAndMacWordsFillTheRest() {
        XCTAssertEqual(
            VoiceBoostWords.merge(typed: ["Testaflight"], fromMac: ["Xcode", "Ollama"]),
            ["Testaflight", "Xcode", "Ollama"]
        )
    }

    func testAWordInBothListsIsBoostedOnce() {
        XCTAssertEqual(
            VoiceBoostWords.merge(typed: ["Ollama"], fromMac: ["ollama", "Xcode"]),
            ["Ollama", "Xcode"]
        )
    }

    func testEitherListAloneIsFine() {
        XCTAssertEqual(VoiceBoostWords.merge(typed: [], fromMac: ["Xcode"]), ["Xcode"])
        XCTAssertEqual(VoiceBoostWords.merge(typed: ["Xcode"], fromMac: []), ["Xcode"])
        XCTAssertEqual(VoiceBoostWords.merge(typed: [], fromMac: []), [])
    }

    /// The screen can offer more than the recogniser should be given, and the
    /// owner's own words are the ones that must survive the trim.
    func testMergeStopsAtTheMaximumAndKeepsTypedWords() {
        let mac = (0..<200).map { "screen\($0)" }
        let merged = VoiceBoostWords.merge(typed: ["Testaflight"], fromMac: mac)
        XCTAssertEqual(merged.count, VoiceBoostWords.maximumPhrases)
        XCTAssertEqual(merged.first, "Testaflight")
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
