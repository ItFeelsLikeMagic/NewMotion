import Foundation
import XCTest
@testable import PhoneRemote_macOS

/// Carries a callback's answer back out of a `@Sendable` closure.
private final class Captured: @unchecked Sendable {
    var value: [String]?
}

/// Stands in for the user's dictionaries so the tests do not depend on which
/// ones the host machine has installed.
private struct KnowsEverything: WordDictionary {
    var except: Set<String> = []
    init(except: Set<String> = []) { self.except = except }
    func isUnknown(_ word: String) -> Bool { except.contains(word) }
}

/// The Mac reads names off its own screen and remembers the ones actually
/// spoken, then pushes the list to the phone, which is where transcription
/// happens. These cover the reading and the remembering.
final class ScreenVocabularyTests: XCTestCase {
    func testScreenVocabularyKeepsNamesAndDropsOrdinaryWords() {
        let phrases = ScreenVocabulary.phrases(in: [
            "The Kubernetes cluster runs NVIDIA GPUs.",
            "Open the file and save it to /Users/kowalczyk/Notes."
        ], dictionary: KnowsEverything())
        XCTAssertTrue(phrases.contains("Kubernetes"))
        XCTAssertTrue(phrases.contains("NVIDIA"))
        XCTAssertTrue(phrases.contains("Notes"))
        XCTAssertTrue(phrases.contains("Users"))
        // Capitalised only because a sentence or a menu started.
        XCTAssertFalse(phrases.contains("The"))
        XCTAssertFalse(phrases.contains("Open"))
        // Ordinary lowercase prose is what the recogniser already knows.
        XCTAssertFalse(phrases.contains("cluster"))
        XCTAssertFalse(phrases.contains("kowalczyk"))
    }

    func testScreenVocabularyRanksByCountAndCaps() {
        let noise = (0..<60).map { "Word\($0)" }.joined(separator: " ")
        let phrases = ScreenVocabulary.phrases(
            in: [noise, "Testaflight Testaflight"], dictionary: KnowsEverything()
        )
        XCTAssertEqual(phrases.first, "Testaflight")
        XCTAssertEqual(VocabularyCache().admit(phrases).count, ScreenVocabulary.maximumPhrases)
    }

    func testLowercaseJargonIsKeptOnlyWhenNoDictionaryKnowsIt() {
        let dictionary = KnowsEverything(except: ["kubectl"])
        XCTAssertTrue(ScreenVocabulary.isCandidate("kubectl", dictionary: dictionary))
        XCTAssertFalse(ScreenVocabulary.isCandidate("cluster", dictionary: dictionary))
    }

    func testKeysAndIdsSurviveSoTheyCanBeDictated() {
        XCTAssertTrue(ScreenVocabulary.isCandidate("4B8P47VZGT", dictionary: KnowsEverything()))
    }

    func testSeeingAWordOnScreenOnlyRenewsTheShortLease() {
        let cache = VocabularyCache(lifetime: 60)
        let start = Date()
        _ = cache.admit(["Alpha", "Bravo"], now: start)
        // Bravo is gone from the screen, but Alpha is walked again.
        let live = cache.admit(["Alpha"], now: start.addingTimeInterval(30))
        XCTAssertEqual(live, ["Alpha", "Bravo"])
        // Seeing it is not a hit, and it buys the short lease, never three hours.
        XCTAssertEqual(cache.stats, VocabularyCache.Statistics(entries: 2, hits: 0, added: 2))
        XCTAssertEqual(cache.current(now: start.addingTimeInterval(80)), ["Alpha"])
        XCTAssertTrue(cache.current(now: start.addingTimeInterval(100)).isEmpty)
    }

    func testSpeakingAWordIsTheHitThatBuysThreeHours() {
        let cache = VocabularyCache(lifetime: 60)
        let start = Date()
        _ = cache.admit(["Testaflight", "Bravo"], now: start)
        cache.heard("we shipped testaflight today")
        XCTAssertEqual(cache.stats.hits, 1)
        // Long past the sighting lease, only the spoken word is still alive.
        XCTAssertEqual(cache.current(now: start.addingTimeInterval(2 * 3_600)), ["Testaflight"])
        XCTAssertTrue(cache.current(now: start.addingTimeInterval(4 * 3_600)).isEmpty)
    }

    func testSpokenWordsOutrankWordsOnlySeen() {
        let cache = VocabularyCache(lifetime: 60)
        _ = cache.admit(["Alpha", "Bravo", "Charlie"])
        cache.heard("charlie")
        XCTAssertEqual(cache.current().first, "Charlie")
    }

    func testAWordNeverSeenOnScreenIsNotInventedBySpeech() {
        let cache = VocabularyCache()
        cache.heard("kubectl")
        XCTAssertTrue(cache.current().isEmpty)
    }

    func testEachSpokenHitAddsThreeHoursOnTopOfWhatIsLeft() {
        let cache = VocabularyCache(lifetime: 60)
        let start = Date()
        _ = cache.admit(["Alpha"], now: start)
        cache.heard("alpha")
        cache.heard("alpha again")
        XCTAssertEqual(cache.stats.hits, 2)
        // Two hits stack to about six hours, rather than resetting to three.
        XCTAssertEqual(cache.current(now: start.addingTimeInterval(5 * 3_600)), ["Alpha"])
        XCTAssertTrue(cache.current(now: start.addingTimeInterval(7 * 3_600)).isEmpty)
    }

    func testAnUtteranceIsAnsweredFromTheCacheWithoutWaitingForAWalk() {
        let cache = VocabularyCache()
        _ = cache.admit(["Testaflight"])
        let reader = AXScreenVocabularyReader(cache: cache, isSecureInputActive: { false })
        // No expectation and no wait: the answer is already in hand.
        let phrases = Captured()
        reader.speechContext { phrases.value = $0 }
        XCTAssertEqual(phrases.value, ["Testaflight"])
    }

    func testCacheEvictsTheWordsLeastSpokenFirst() {
        let cache = VocabularyCache(lifetime: 60, capacity: 2)
        let start = Date()
        _ = cache.admit(["Charlie"], now: start)
        cache.heard("charlie")
        _ = cache.admit(["Alpha", "Bravo", "Charlie"], now: start.addingTimeInterval(1))
        // Two seats, three words: the spoken one keeps its seat and the words
        // only seen compete for what is left in the order the walk found them.
        XCTAssertEqual(cache.current(now: start.addingTimeInterval(2)), ["Charlie", "Alpha"])
    }

    func testScreenVocabularyRejectsTokensThatCannotHelp() {
        let dictionary = KnowsEverything()
        XCTAssertFalse(ScreenVocabulary.isCandidate("Hi", dictionary: dictionary))
        XCTAssertFalse(ScreenVocabulary.isCandidate("2026", dictionary: dictionary))
        XCTAssertFalse(ScreenVocabulary.isCandidate(String(repeating: "A", count: 25), dictionary: dictionary))
        XCTAssertTrue(ScreenVocabulary.isCandidate("Xcode", dictionary: dictionary))
    }

    func testScreenVocabularyReaderStaysQuietWhenOffOrSecure() {
        let off = AXScreenVocabularyReader(isEnabled: false, isSecureInputActive: { false })
        let secure = AXScreenVocabularyReader(isEnabled: true, isSecureInputActive: { true })
        XCTAssertEqual(off.lastWalk, ScreenVocabularyWalk())
        for reader in [off, secure] {
            let done = expectation(description: "speech context")
            reader.speechContext { phrases in
                XCTAssertTrue(phrases.isEmpty)
                done.fulfill()
            }
            wait(for: [done], timeout: 1)
        }
    }

    /// Reading our own process re-enters AppKit's accessibility path on the
    /// walk queue, which drives a SwiftUI update off the main thread and traps
    /// on the first main-actor property it reaches. It crashed the Mac app the
    /// first time the walk ran while the app itself was frontmost.
    func testTheWalkRefusesToReadItsOwnProcess() throws {
        let ownBundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let reader = AXScreenVocabularyReader(isEnabled: true, isSecureInputActive: { false })
        let report = reader.probe(bundleID: ownBundleID)
        XCTAssertEqual(report["app"], "self")
        XCTAssertEqual(report["words"], "0")
    }
}
