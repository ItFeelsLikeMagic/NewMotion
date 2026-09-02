import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

final class SafetyFeatureTests: XCTestCase {
    func testPolicyDeniesUntilEveryControlPreconditionIsSatisfied() {
        var machine = InputSafetyStateMachine()
        XCTAssertEqual(machine.evaluate(.pointer(MacPointerDelta(x: 1, y: 2))), .deny(.unauthenticated))

        var state = machine.state
        state.authentication = .authenticated
        state.accessibility = .granted
        XCTAssertEqual(machine.transition(to: state).actions, [])
        XCTAssertEqual(machine.evaluate(.pointer(MacPointerDelta(x: 1, y: 2))), .allow(.pointer(MacPointerDelta(x: 1, y: 2))))

        state.activity = .paused
        XCTAssertEqual(machine.transition(to: state).actions, [.releaseAllInputs(reason: .pause)])
        XCTAssertEqual(machine.evaluate(.pointer(MacPointerDelta(x: 1, y: 2))), .deny(.paused))
    }

    func testUnsafeTransitionReleasesTrackedStateOnce() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        var machine = InputSafetyStateMachine(state: state)
        XCTAssertEqual(machine.evaluate(.mouseButton(button: .left, isDown: true)), .allow(.mouseButton(button: .left, isDown: true)))
        XCTAssertEqual(machine.evaluate(.modifier(key: .command, isDown: true)), .allow(.modifier(key: .command, isDown: true)))

        state.lock = .locked
        let transition = machine.transition(to: state)
        XCTAssertEqual(transition.actions, [.releaseAllInputs(reason: .lock)])
        XCTAssertTrue(machine.held.isEmpty)
        XCTAssertEqual(machine.transition(to: state).actions, [])
    }

    func testMockSinkAndHotkeyUseOnlyPolicyPath() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)

        XCTAssertEqual(injector.submit(.mouseButton(button: .left, isDown: true)), .applied)
        XCTAssertEqual(injector.submit(.hotkey(.copy)), .applied)
        XCTAssertEqual(sink.events, [
            .mouseButton(button: .left, isDown: true),
            .physicalKey(keyCode: 55, isDown: true),
            .physicalKey(keyCode: 8, isDown: true),
            .physicalKey(keyCode: 8, isDown: false),
            .physicalKey(keyCode: 55, isDown: false)
        ])

        var paused = injector.state
        paused.activity = .paused
        _ = injector.transition(to: paused)
        XCTAssertEqual(injector.submit(.pointer(MacPointerDelta(x: 1, y: 1))), .denied(.paused))
        XCTAssertEqual(sink.events.last, .mouseButton(button: .left, isDown: false))
    }

    func testReliableDuplicatesAreAcknowledgedAndWatchdogReleases() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)
        let clock = TestInputClock(now: 10)
        let coordinator = ReliableInputCoordinator(injector: injector, clock: clock)
        let action = ReliableInputAction(actionID: 7, command: .mouseButton(button: .left, isDown: true))

        XCTAssertEqual(coordinator.receive(action, at: 10), [.applied(actionID: 7), .acknowledgement(actionID: 7)])
        XCTAssertEqual(coordinator.receive(action, at: 10.1), [.acknowledgement(actionID: 7)])
        XCTAssertEqual(sink.events.filter { $0 == .mouseButton(button: .left, isDown: true) }.count, 1)
        XCTAssertEqual(coordinator.poll(at: 10.5), [.watchdogExpired, .released(reason: .heartbeatTimeout)])
        XCTAssertEqual(sink.events.last, .mouseButton(button: .left, isDown: false))
        XCTAssertEqual(coordinator.poll(at: 11), [])
    }

    func testRetryTrackerHasFiniteAttemptsAndBoundedQueue() {
        var tracker = ReliableRetryTracker(acknowledgementTimeout: 0.1, maxAttempts: 2, maxPending: 1)
        let action = ReliableInputAction(actionID: 1, command: .mouseButton(button: .left, isDown: true))
        XCTAssertTrue(tracker.enqueue(action, at: 0))
        XCTAssertFalse(tracker.enqueue(ReliableInputAction(actionID: 2, command: .mouseButton(button: .right, isDown: true)), at: 0))
        XCTAssertEqual(tracker.poll(at: 0.1), [.retry(action, attempt: 2)])
        XCTAssertEqual(tracker.poll(at: 0.2), [.exhausted(action)])
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testAudioReassemblerAccountsGapsAndDuplicates() throws {
        let sink = InMemoryPCMDataSink()
        let reassembler = AudioPCMReassembler(sink: sink, maxSyntheticGapSamples: 20)
        try reassembler.start()
        let first = try XCTUnwrap(MacAudioPCMChunk(
            sequence: 0,
            timestamp: 1,
            samplePosition: 0,
            sampleCount: 4,
            pcmLittleEndian: Data(repeating: 1, count: 8),
            level: 0.25
        ))
        let third = try XCTUnwrap(MacAudioPCMChunk(
            sequence: 2,
            timestamp: 1.1,
            samplePosition: 8,
            sampleCount: 4,
            pcmLittleEndian: Data(repeating: 2, count: 8),
            level: 0.5
        ))
        XCTAssertEqual(reassembler.receive(first), .accepted)
        XCTAssertEqual(reassembler.receive(first), .duplicate)
        XCTAssertEqual(reassembler.receive(third), .gapFilled(samples: 4))
        let health = try reassembler.finish()
        XCTAssertEqual(health.receivedChunks, 2)
        XCTAssertEqual(health.receivedSamples, 8)
        XCTAssertEqual(health.missingChunks, 1)
        XCTAssertEqual(health.missingSamples, 4)
        XCTAssertEqual(health.durationSeconds, 12.0 / 16_000.0, accuracy: 1e-9)
        XCTAssertTrue(sink.finished)
    }

    func testVoicePTTStreamsThenTypesOnClose() throws {
        let sink = TestTranscriptSink()
        let provider = TestStreamingSpeechProvider(result: .success("hello world"))
        let coordinator = VoicePTTCoordinator(streaming: provider, insertionSink: sink)
        let streamID = try SessionID(bytes: Array(repeating: 9, count: SessionID.byteCount))
        var encoder = IMAADPCMEncoder()
        let samples: [Int16] = [1_000, -1_000, 2_000, -2_000]
        let start = try VoiceStreamFrame(
            flags: .start,
            streamID: streamID,
            sequence: 0,
            sampleCount: 0,
            payload: Data()
        )
        let data = try VoiceStreamFrame(
            flags: [],
            streamID: streamID,
            sequence: 1,
            sampleCount: 4,
            payload: encoder.encode(samples)
        )
        let end = try VoiceStreamFrame(
            flags: .end,
            streamID: streamID,
            sequence: 2,
            sampleCount: 0,
            payload: Data()
        )
        coordinator.receive(start)
        XCTAssertEqual(provider.began, 1)
        XCTAssertTrue(sink.values.isEmpty)
        coordinator.receive(data)
        XCTAssertFalse(provider.samples.isEmpty)
        XCTAssertTrue(sink.values.isEmpty)
        coordinator.receive(end)
        XCTAssertEqual(provider.ended, 1)
        XCTAssertEqual(sink.values, ["hello world"])
        XCTAssertEqual(coordinator.phase, .typed)
    }

    func testTranscriptHelperLineHidesFailuresAndEmptyReady() {
        XCTAssertNil(TranscriptHelperLine.parse("READY"))
        XCTAssertEqual(TranscriptHelperLine.parse("OK hello there"), .success("hello there"))
        XCTAssertEqual(TranscriptHelperLine.parse("OK "), .success(""))
        XCTAssertEqual(TranscriptHelperLine.parse("ERR"), .failure(.failed))
    }

    func testTranscriptRequiresExplicitInsertion() {
        let sink = TestTranscriptSink()
        let controller = ExplicitTranscriptInsertionController(insertionSink: sink)
        controller.receiveFinalTranscript("private text")
        XCTAssertTrue(sink.values.isEmpty)
        XCTAssertTrue(controller.insertPendingTranscript())
        XCTAssertEqual(sink.values, ["private text"])
        XCTAssertFalse(controller.insertPendingTranscript())
    }

    func testLifecycleMapsPauseAndLockToSafeStatus() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)
        let lifecycle = MacLifecycleCoordinator(injector: injector)
        XCTAssertEqual(lifecycle.status(), .connected)
        XCTAssertEqual(lifecycle.handle(.userPause).status, .paused)
        XCTAssertEqual(lifecycle.handle(.userResume).status, .connected)
        XCTAssertEqual(lifecycle.handle(.lock).status, .disconnected)
        XCTAssertEqual(lifecycle.handle(.unlock).reconnect, .eligibleWhenBothAppsActive)
    }
}

private final class TestInputClock: InputSafetyClock {
    var now: TimeInterval
    init(now: TimeInterval) { self.now = now }
}

private final class TestTranscriptSink: SafeTranscriptInsertionSink {
    var values: [String] = []
    func insertTranscript(_ text: String) -> Bool {
        values.append(text)
        return true
    }
}
