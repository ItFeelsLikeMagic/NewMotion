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
            VoiceBoostWords.parse("Nemotron, Ollama\nXcode"),
            ["Nemotron", "Ollama", "Xcode"]
        )
    }

    func testTrimsSpacesAndDropsEmptyEntries() {
        XCTAssertEqual(
            VoiceBoostWords.parse("  Nemotron ,, \n , Ollama  \n\n"),
            ["Nemotron", "Ollama"]
        )
    }

    func testKeepsTheFirstSpellingOfARepeatedPhrase() {
        XCTAssertEqual(
            VoiceBoostWords.parse("Nemotron, nemotron, NEMOTRON, Ollama"),
            ["Nemotron", "Ollama"]
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
