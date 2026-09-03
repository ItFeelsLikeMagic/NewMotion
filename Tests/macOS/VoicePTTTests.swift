import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

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

    // MARK: - Helpers

    private func makeCoordinator(
        idleTimeout: TimeInterval = 5,
        secureInput: Bool = false,
        normalizer: TranscriptNormalizer? = nil
    ) -> (VoicePTTCoordinator, FakeSessionFactory, RecordingSink) {
        let factory = FakeSessionFactory()
        let sink = RecordingSink()
        let coordinator = VoicePTTCoordinator(
            sessions: factory,
            insertionSink: sink,
            normalizer: normalizer,
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

    func insertTranscript(_ text: String) -> Bool {
        values.append(text)
        return true
    }
}
