import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

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

final class VoicePTTTests: XCTestCase {
    private let streamA = try! SessionID(bytes: Array(repeating: 1, count: SessionID.byteCount))
    private let streamB = try! SessionID(bytes: Array(repeating: 2, count: SessionID.byteCount))

    func testOpensSessionOnStartAndFeedsPCMPerFrame() throws {
        let (coordinator, factory, sink) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        XCTAssertTrue(waitUntil { factory.sessions.count == 1 })
        XCTAssertEqual(coordinator.state.phase, .listening)

        coordinator.receive(try frame(streamA, sequence: 1, samples: [1_000, -1_000, 2_000, -2_000]))
        XCTAssertTrue(waitUntil { factory.sessions[0].sampleCount == 4 })
        coordinator.receive(try frame(streamA, sequence: 2, samples: [500, 500, 500, 500]))
        XCTAssertTrue(waitUntil { factory.sessions[0].sampleCount == 8 })
        XCTAssertFalse(factory.sessions[0].committed)
        XCTAssertTrue(sink.values.isEmpty)
        XCTAssertEqual(coordinator.state.health.receivedFrames, 3)
        XCTAssertEqual(coordinator.state.health.receivedSamples, 8)
    }

    func testEndCommitsAndTypesFinalOnce() throws {
        let (coordinator, factory, sink) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, samples: [1, 2, 3, 4]))
        coordinator.receive(try frame(streamA, sequence: 2, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })
        XCTAssertEqual(coordinator.state.phase, .transcribing)
        XCTAssertTrue(sink.values.isEmpty)

        factory.sessions[0].handlers.onDelta("hello")
        XCTAssertTrue(waitUntil { coordinator.state.preview == "hello" })
        factory.sessions[0].handlers.onResult(.success(" hello world \n"))
        XCTAssertTrue(waitUntil { sink.values == ["hello world"] })
        XCTAssertEqual(coordinator.state.phase, .typed)
        XCTAssertEqual(coordinator.state.lastFinalText, "hello world")
        XCTAssertEqual(coordinator.state.preview, "")

        factory.sessions[0].handlers.onResult(.success("hello world"))
        XCTAssertFalse(waitUntil(timeout: 0.2) { sink.values.count > 1 })
    }

    func testIdleTimeoutCommits() throws {
        let (coordinator, factory, _) = makeCoordinator(idleTimeout: 0.05)
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, samples: [1, 2, 3, 4]))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })
        XCTAssertEqual(coordinator.state.phase, .transcribing)

        // Late frames for the committed stream are dropped, not restarted.
        coordinator.receive(try frame(streamA, sequence: 2, samples: [1, 2, 3, 4]))
        XCTAssertFalse(waitUntil(timeout: 0.1) { factory.sessions.count > 1 })
    }

    func testOverlappingUtterancesTypeInStartOrder() throws {
        let (coordinator, factory, sink) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        coordinator.receive(try frame(streamB, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamB, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.count == 2 && factory.sessions.allSatisfy(\.committed) })

        factory.sessions[1].handlers.onResult(.success("second"))
        XCTAssertFalse(waitUntil(timeout: 0.1) { !sink.values.isEmpty })
        XCTAssertEqual(coordinator.state.phase, .transcribing)

        factory.sessions[0].handlers.onResult(.success("first"))
        XCTAssertTrue(waitUntil { sink.values == ["first", "second"] })
        XCTAssertEqual(coordinator.state.phase, .typed)
    }

    func testFailedEarlierUtteranceDoesNotBlockLaterOne() throws {
        let (coordinator, factory, sink) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        coordinator.receive(try frame(streamB, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamB, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.count == 2 })

        factory.sessions[1].handlers.onResult(.success("second"))
        factory.sessions[0].handlers.onResult(.failure(.serverError))
        XCTAssertTrue(waitUntil { sink.values == ["second"] })
    }

    func testSequenceGapsAreCounted() throws {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, samples: [1, 2, 3, 4]))
        coordinator.receive(try frame(streamA, sequence: 4, samples: [1, 2, 3, 4]))
        coordinator.receive(try frame(streamA, sequence: 5, flags: .end))
        XCTAssertTrue(waitUntil { coordinator.state.health.receivedFrames == 4 })
        XCTAssertEqual(coordinator.state.health.missingChunks, 2)
        XCTAssertEqual(coordinator.state.health.receivedSamples, 8)
    }

    func testLostStartFrameStillOpensSessionAndCountsGap() throws {
        let (coordinator, factory, _) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 3, samples: [1, 2, 3, 4]))
        XCTAssertTrue(waitUntil { factory.sessions.count == 1 })
        XCTAssertEqual(coordinator.state.health.missingChunks, 2)
        XCTAssertEqual(coordinator.state.phase, .listening)
    }

    func testSecureInputSkipsTyping() throws {
        let (coordinator, factory, sink) = makeCoordinator(secureInput: true)
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })
        factory.sessions[0].handlers.onResult(.success("password"))
        XCTAssertTrue(waitUntil { coordinator.state.phase == .failed })
        XCTAssertTrue(sink.values.isEmpty)
        XCTAssertNil(coordinator.state.lastFinalText)
    }

    func testEmptyFinalTypesNothing() throws {
        let (coordinator, factory, sink) = makeCoordinator()
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })
        factory.sessions[0].handlers.onResult(.success("  "))
        XCTAssertTrue(waitUntil { coordinator.state.phase == .idle })
        XCTAssertTrue(sink.values.isEmpty)
    }

    func testUnicodeChunksAreAtMostTwentyUnitsAndKeepSurrogatePairs() {
        let plain = UnicodeKeyEvents.chunks(of: String(repeating: "a", count: 45))
        XCTAssertEqual(plain.map(\.count), [20, 20, 5])

        let emojiOnBoundary = String(repeating: "a", count: 19) + "😀b"
        let chunks = UnicodeKeyEvents.chunks(of: emojiOnBoundary)
        XCTAssertEqual(chunks.map(\.count), [19, 3])
        XCTAssertEqual(String(utf16CodeUnits: chunks.flatMap { $0 }, count: 22), emojiOnBoundary)
        XCTAssertTrue(UnicodeKeyEvents.chunks(of: "").isEmpty)
    }

    func testRealtimeEventParsing() {
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"audio_processed":0.84,"delta":"Hel","event_id":"event_10","type":"conversation.item.input_audio_transcription.delta"}"#),
            .delta("Hel")
        )
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"audio_processed":3.4,"event_id":"event_78","transcript":"Hello there.","type":"conversation.item.input_audio_transcription.completed"}"#),
            .completed(transcript: "Hello there.")
        )
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"error":{"message":"session configuration cannot change after audio starts","type":"invalid_request_error"},"event_id":"event_77","type":"error"}"#),
            .error(message: "session configuration cannot change after audio starts")
        )
        XCTAssertEqual(
            RealtimeServerEvent.parse(#"{"event_id":"event_3","session":{"sample_rate":16000},"type":"session.created"}"#),
            .sessionCreated
        )
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"event_id":"event_6","type":"input_audio_buffer.committed"}"#), .committed)
        XCTAssertNil(RealtimeServerEvent.parse(#"{"type":"something.else"}"#))
        XCTAssertNil(RealtimeServerEvent.parse("not json"))
    }

    func testNormalizerRewritesFinalBeforeTyping() throws {
        let normalizer = FakeNormalizer { _ in "I am going to be late." }
        let (coordinator, factory, sink) = makeCoordinator(normalizer: normalizer)
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("um im gonna be late"))
        XCTAssertTrue(waitUntil { sink.values == ["I am going to be late."] })
        XCTAssertEqual(normalizer.inputs, ["um im gonna be late"])
        XCTAssertEqual(coordinator.state.lastFinalText, "I am going to be late.")
        XCTAssertEqual(coordinator.state.phase, .typed)
    }

    func testNormalizerEmptyResultTypesNothing() throws {
        let (coordinator, factory, sink) = makeCoordinator(normalizer: FakeNormalizer { _ in "" })
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("um uh"))
        XCTAssertTrue(waitUntil { coordinator.state.phase == .idle })
        XCTAssertTrue(sink.values.isEmpty)
    }

    func testSlowNormalizerKeepsTypedOrder() throws {
        let normalizer = FakeNormalizer(delay: 0.2) { $0.uppercased() }
        let (coordinator, factory, sink) = makeCoordinator(normalizer: normalizer)
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        coordinator.receive(try frame(streamB, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamB, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.count == 2 })

        factory.sessions[1].handlers.onResult(.success("second"))
        factory.sessions[0].handlers.onResult(.success("first"))
        XCTAssertTrue(waitUntil { sink.values == ["FIRST", "SECOND"] })
    }

    func testSecureInputSkipsTypingAfterNormalizing() throws {
        let normalizer = FakeNormalizer { _ in "My password is hunter two." }
        let (coordinator, factory, sink) = makeCoordinator(secureInput: true, normalizer: normalizer)
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("my password is hunter two"))
        XCTAssertTrue(waitUntil { coordinator.state.phase == .failed })
        XCTAssertTrue(sink.values.isEmpty)
        XCTAssertNil(coordinator.state.lastFinalText)
    }

    func testS1MiniPromptMatchesTheTrainedFormat() {
        XCTAssertEqual(
            S1MiniNormalizer.prompt(for: "hello there"),
            "<|im_start|>system\n" + S1MiniNormalizer.systemPrompt + "<|im_end|>\n"
                + "<|im_start|>user\n[Styling: semi-formal] [Structure: prose] [Context: general]\n"
                + "hello there<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
    }

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
            in: [noise, "Nemotron Nemotron"], dictionary: KnowsEverything()
        )
        XCTAssertEqual(phrases.first, "Nemotron")
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
        _ = cache.admit(["Nemotron", "Bravo"], now: start)
        cache.heard("we shipped nemotron today")
        XCTAssertEqual(cache.stats.hits, 1)
        // Long past the sighting lease, only the spoken word is still alive.
        XCTAssertEqual(cache.current(now: start.addingTimeInterval(2 * 3_600)), ["Nemotron"])
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
        _ = cache.admit(["Nemotron"])
        let reader = AXScreenVocabularyReader(cache: cache, isSecureInputActive: { false })
        // No expectation and no wait: the answer is already in hand.
        let phrases = Captured()
        reader.speechContext { phrases.value = $0 }
        XCTAssertEqual(phrases.value, ["Nemotron"])
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

    func testSessionUpdateCarriesTheBoostList() throws {
        let event = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(NemotronRealtimeSession.sessionUpdate(phrases: ["Nemotron"]).utf8)
        ) as? [String: Any])
        XCTAssertEqual(event["type"] as? String, "session.update")
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["sample_rate"] as? Int, NemotronRealtimeSession.sampleRate)
        let contexts = try XCTUnwrap(session["speech_contexts"] as? [[String: Any]])
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0]["phrases"] as? [String], ["Nemotron"])
        XCTAssertEqual(contexts[0]["boost"] as? Double, NemotronRealtimeSession.speechContextBoost)
    }

    func testSessionUpdateOmitsTheBoostListWhenThereIsNothingToBoost() throws {
        let event = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(NemotronRealtimeSession.sessionUpdate(phrases: []).utf8)
        ) as? [String: Any])
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["sample_rate"] as? Int, NemotronRealtimeSession.sampleRate)
        XCTAssertNil(session["speech_contexts"])
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

    func testS1MiniResponseParsing() {
        XCTAssertEqual(
            S1MiniNormalizer.normalized(fromResponse: Data(#"{"model":"s1-mini","response":"Hello there.\n","done":true}"#.utf8)),
            "Hello there."
        )
        // Filler-only speech normalizes to nothing, which is a result, not a failure.
        XCTAssertEqual(S1MiniNormalizer.normalized(fromResponse: Data(#"{"response":""}"#.utf8)), "")
        XCTAssertNil(S1MiniNormalizer.normalized(fromResponse: Data(#"{"error":"model not found"}"#.utf8)))
        XCTAssertNil(S1MiniNormalizer.normalized(fromResponse: Data("not json".utf8)))
    }

    func testExistingFieldTextIsNormalizedWithTheNewWords() throws {
        let normalizer = FakeNormalizer { _ in "Hello there. How are you?" }
        let (coordinator, factory, sink) = makeCoordinator(
            normalizer: normalizer,
            focusedText: FakeFocusedText([.text("Hello there.")])
        )
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("how are you"))
        XCTAssertTrue(waitUntil { sink.values == [" How are you?"] })
        XCTAssertEqual(normalizer.inputs, ["Hello there. how are you"])
        XCTAssertEqual(sink.deletions, [])
        XCTAssertEqual(coordinator.state.merge, "merged")
    }

    func testRewordedFieldTextIsCorrectedInPlace() throws {
        let normalizer = FakeNormalizer { _ in "Hello there. How are you?" }
        let (coordinator, factory, sink) = makeCoordinator(
            normalizer: normalizer,
            focusedText: FakeFocusedText([.text("hello there")])
        )
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("how are you"))
        XCTAssertTrue(waitUntil { sink.values == ["Hello there. How are you?"] })
        XCTAssertEqual(sink.deletions, ["hello there".count])
    }

    func testFieldChangingDuringNormalizationTypesOnlyTheNewWords() throws {
        let normalizer = FakeNormalizer { _ in "Hello there. How are you?" }
        let (coordinator, factory, sink) = makeCoordinator(
            normalizer: normalizer,
            focusedText: FakeFocusedText([.text("Hello there."), .text("Hello there. and more")])
        )
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("how are you"))
        XCTAssertTrue(waitUntil { sink.values == [" how are you"] })
        XCTAssertEqual(sink.deletions, [])
        XCTAssertEqual(coordinator.state.merge, "appended")
    }

    func testUnreadableFieldKeepsThePlainPath() throws {
        let normalizer = FakeNormalizer { _ in "How are you?" }
        let (coordinator, factory, sink) = makeCoordinator(
            normalizer: normalizer,
            focusedText: FakeFocusedText([.unavailable("focus:-25204")])
        )
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        coordinator.receive(try frame(streamA, sequence: 1, flags: .end))
        XCTAssertTrue(waitUntil { factory.sessions.first?.committed == true })

        factory.sessions[0].handlers.onResult(.success("how are you"))
        XCTAssertTrue(waitUntil { sink.values == ["How are you?"] })
        XCTAssertEqual(normalizer.inputs, ["how are you"])
        XCTAssertEqual(coordinator.state.merge, "focus:-25204")
    }

    func testFieldIsWokenWhenTheSpeakerStartsNotWhenTheyStop() throws {
        let field = FakeFocusedText([.text("Hello there.")])
        let (coordinator, factory, _) = makeCoordinator(
            normalizer: FakeNormalizer { $0 },
            focusedText: field
        )
        coordinator.receive(try frame(streamA, sequence: 0, flags: .start))
        XCTAssertTrue(waitUntil { field.prepared == 1 })
        XCTAssertTrue(factory.sessions[0].sampleCount == 0)
    }

    func testMergeBuildsThePayloadAndTheSmallestEdit() {
        XCTAssertEqual(TranscriptMerge.payload(existing: "Hi.", transcript: "there"), "Hi. there")
        XCTAssertEqual(TranscriptMerge.payload(existing: "Hi.\n", transcript: "there"), "Hi.\nthere")
        XCTAssertEqual(TranscriptMerge.payload(existing: "", transcript: "there"), "there")

        XCTAssertEqual(
            TranscriptMerge.edit(from: "Hi.", to: "Hi. There."),
            TranscriptMerge.Edit(deletions: 0, insertion: " There.")
        )
        XCTAssertEqual(
            TranscriptMerge.edit(from: "hi", to: "Hi. There."),
            TranscriptMerge.Edit(deletions: 2, insertion: "Hi. There.")
        )
        // A rewrite that would rewind more than the budget is refused whole.
        let long = String(repeating: "a", count: TranscriptMerge.maximumDeletions + 1)
        XCTAssertNil(TranscriptMerge.edit(from: long, to: "something else"))
    }

    // MARK: - Helpers

    private func makeCoordinator(
        idleTimeout: TimeInterval = 5,
        secureInput: Bool = false,
        normalizer: TranscriptNormalizer? = nil,
        focusedText: FocusedTextReading? = nil
    ) -> (VoicePTTCoordinator, FakeSessionFactory, RecordingSink) {
        let factory = FakeSessionFactory()
        let sink = RecordingSink()
        let coordinator = VoicePTTCoordinator(
            sessions: factory,
            insertionSink: sink,
            normalizer: normalizer,
            focusedText: focusedText,
            idleTimeout: idleTimeout,
            isSecureInputActive: { secureInput }
        )
        return (coordinator, factory, sink)
    }

    private func frame(
        _ streamID: SessionID,
        sequence: UInt32,
        flags: VoiceStreamFlags = [],
        samples: [Int16] = []
    ) throws -> VoiceStreamFrame {
        var encoder = IMAADPCMEncoder()
        return try VoiceStreamFrame(
            flags: flags,
            streamID: streamID,
            sequence: sequence,
            sampleCount: UInt16(samples.count),
            payload: samples.isEmpty ? Data() : encoder.encode(samples)
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class FakeSession: TranscriptionSession, @unchecked Sendable {
    let handlers: TranscriptionSessionHandlers
    private let lock = NSLock()
    private var _sampleCount = 0
    private var _committed = false

    init(handlers: TranscriptionSessionHandlers) {
        self.handlers = handlers
    }

    var sampleCount: Int { lock.withLock { _sampleCount } }
    var committed: Bool { lock.withLock { _committed } }

    func send(pcm16: [Int16]) {
        lock.withLock { _sampleCount += pcm16.count }
    }

    func commit() {
        lock.withLock { _committed = true }
    }
}

private final class FakeSessionFactory: TranscriptionSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [FakeSession] = []

    var sessions: [FakeSession] { lock.withLock { _sessions } }

    func makeSession(handlers: TranscriptionSessionHandlers) -> TranscriptionSession {
        let session = FakeSession(handlers: handlers)
        lock.withLock { _sessions.append(session) }
        return session
    }
}

private final class FakeNormalizer: TranscriptNormalizer, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let transform: @Sendable (String) -> String
    private var _inputs: [String] = []

    init(delay: TimeInterval = 0, _ transform: @escaping @Sendable (String) -> String) {
        self.delay = delay
        self.transform = transform
    }

    var inputs: [String] { lock.withLock { _inputs } }

    func normalize(_ transcript: String, completion: @escaping @Sendable (String) -> Void) {
        lock.withLock { _inputs.append(transcript) }
        let transform = transform
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            completion(transform(transcript))
        }
    }
}

private final class RecordingSink: SafeTranscriptInsertionSink {
    var values: [String] = []
    var deletions: [Int] = []

    func insertTranscript(_ text: String) -> Bool {
        values.append(text)
        return true
    }

    func deleteBackward(_ count: Int) -> Bool {
        deletions.append(count)
        return true
    }
}

/// Answers with a scripted field, one reading per call, so a test can make the
/// field change between the read that feeds the normalizer and the one that
/// checks the field before typing.
private final class FakeFocusedText: FocusedTextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [FocusedText]
    private var _prepared = 0

    init(_ readings: [FocusedText]) {
        self.readings = readings
    }

    var prepared: Int { lock.withLock { _prepared } }

    func focusedText() -> FocusedText {
        lock.withLock { readings.count > 1 ? readings.removeFirst() : readings[0] }
    }

    func prepare() {
        lock.withLock { _prepared += 1 }
    }
}
