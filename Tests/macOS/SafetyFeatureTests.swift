import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

final class SafetyFeatureTests: XCTestCase {
    func testUnicodeChunksAreAtMostTwentyUnitsAndKeepSurrogatePairs() {
        let plain = UnicodeKeyEvents.chunks(of: String(repeating: "a", count: 45))
        XCTAssertEqual(plain.map(\.count), [20, 20, 5])

        let emojiOnBoundary = String(repeating: "a", count: 19) + "😀b"
        let chunks = UnicodeKeyEvents.chunks(of: emojiOnBoundary)
        XCTAssertEqual(chunks.map(\.count), [19, 3])
        XCTAssertEqual(String(utf16CodeUnits: chunks.flatMap { $0 }, count: 22), emojiOnBoundary)
        XCTAssertTrue(UnicodeKeyEvents.chunks(of: "").isEmpty)
    }

    /// The whole point of the watchdog: a phone that stops talking must not
    /// leave a button pressed.
    func testWatchdogReleasesAHeldButtonWhenTheHeartbeatStops() {
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: controllablePolicy(), sink: sink)
        let coordinator = ReliableInputCoordinator(injector: injector, heartbeatTimeout: 1.0)

        XCTAssertEqual(injector.submit(.mouseButton(button: .left, isDown: true, clickCount: 2)), .applied)
        coordinator.receive(heartbeat: InputHeartbeat(held: HeldInputState(buttons: [.left])), at: 0)
        sink.removeAll()

        // Still inside the window: nothing happens.
        XCTAssertEqual(coordinator.poll(at: 0.9), [])
        XCTAssertTrue(sink.events.isEmpty)

        XCTAssertEqual(
            coordinator.poll(at: 1.1),
            [.watchdogExpired, .released(reason: .heartbeatTimeout)]
        )
        XCTAssertEqual(sink.events, [.mouseButton(button: .left, isDown: false, clickCount: 1)])

        // One expiry is enough; further polls stay quiet until a new beat.
        sink.removeAll()
        XCTAssertEqual(coordinator.poll(at: 5), [])
        XCTAssertTrue(sink.events.isEmpty)
    }

    /// A remote that holds nothing arms nothing, so an idle link can never be
    /// interrupted by a release it did not need.
    func testWatchdogStaysQuietWhenNothingIsHeld() {
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: controllablePolicy(), sink: sink)
        let coordinator = ReliableInputCoordinator(injector: injector, heartbeatTimeout: 1.0)

        XCTAssertEqual(coordinator.poll(at: 10), [])

        coordinator.receive(heartbeat: InputHeartbeat(), at: 0)
        sink.removeAll()
        XCTAssertEqual(coordinator.poll(at: 2).count, 2)
        XCTAssertTrue(sink.events.isEmpty, "nothing was held, so nothing should be released")
    }

    /// A heartbeat carries the whole held set, not a change to it, so a press
    /// that never arrived is repaired by the next beat.
    func testHeartbeatReconcilesAPressThatNeverArrived() {
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: controllablePolicy(), sink: sink)
        let coordinator = ReliableInputCoordinator(injector: injector, heartbeatTimeout: 1.0)

        coordinator.receive(heartbeat: InputHeartbeat(held: HeldInputState(buttons: [.left])), at: 0)
        XCTAssertEqual(sink.events, [.mouseButton(button: .left, isDown: true, clickCount: 1)])
        XCTAssertEqual(injector.held.buttons, [.left])

        // A beat that repeats the same set changes nothing.
        sink.removeAll()
        coordinator.receive(heartbeat: InputHeartbeat(held: HeldInputState(buttons: [.left])), at: 0.25)
        XCTAssertTrue(sink.events.isEmpty)

        // A beat that drops it releases it.
        coordinator.receive(heartbeat: InputHeartbeat(), at: 0.5)
        XCTAssertEqual(sink.events, [.mouseButton(button: .left, isDown: false, clickCount: 1)])
    }

    /// Both ends read the same byte, so the trip out and back has to be exact.
    func testHeldStateSurvivesTheHeartbeatWireFormat() {
        let held = HeldInputState(buttons: [.left, .right], modifiers: [.command, .shift])
        let payload = SharedInputProtocolAdapter.heartbeat(for: held)
        XCTAssertEqual(SharedInputProtocolAdapter.held(from: payload), held)

        let empty = SharedInputProtocolAdapter.heartbeat(for: HeldInputState())
        XCTAssertEqual(empty.buttons, 0)
        XCTAssertEqual(empty.modifiers, 0)
        XCTAssertTrue(SharedInputProtocolAdapter.held(from: empty).isEmpty)
    }

    private func controllablePolicy() -> InputSafetyStateMachine {
        InputSafetyStateMachine(state: InputControlState(
            authentication: .authenticated,
            accessibility: .granted
        ))
    }

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
        XCTAssertEqual(
            machine.evaluate(.mouseButton(button: .left, isDown: true, clickCount: 2)),
            .allow(.mouseButton(button: .left, isDown: true, clickCount: 2))
        )
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

        XCTAssertEqual(injector.submit(.mouseButton(button: .left, isDown: true, clickCount: 1)), .applied)
        XCTAssertEqual(injector.submit(.hotkey(.copy)), .applied)
        XCTAssertEqual(sink.events, [
            .mouseButton(button: .left, isDown: true, clickCount: 1),
            .hotkey(HotkeyPhysicalSequence.transitions(for: .copy))
        ])

        var paused = injector.state
        paused.activity = .paused
        _ = injector.transition(to: paused)
        XCTAssertEqual(injector.submit(.pointer(MacPointerDelta(x: 1, y: 1))), .denied(.paused))
        XCTAssertEqual(sink.events.last, .mouseButton(button: .left, isDown: false, clickCount: 1))
    }

    func testDoubleClickIsOneAtomicEventAndHoldsNoButton() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)

        XCTAssertEqual(injector.submit(.doubleClick(.left)), .applied)
        XCTAssertEqual(sink.events, [.mouseDoubleClick(button: .left)])
        XCTAssertTrue(injector.held.isEmpty)
    }

    func testTheWalkHoldsItsModifierUntilCommitAndReleasesItOnDisconnect() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)

        for command in SharedInputProtocolAdapter.commands(for: walk(.begin)) {
            XCTAssertEqual(injector.submit(command), .applied)
        }
        XCTAssertEqual(sink.events, [
            .modifier(key: .command, isDown: true),
            .hotkey(HotkeyPhysicalSequence.transitions(for: .tab))
        ])
        XCTAssertTrue(injector.held.modifiers.contains(.command))

        for command in SharedInputProtocolAdapter.commands(for: walk(.previous)) {
            XCTAssertEqual(injector.submit(command), .applied)
        }
        XCTAssertEqual(sink.events.last, .hotkey(HotkeyPhysicalSequence.transitions(for: .shiftTab)))

        // Losing the phone mid-hold must not strand the Command key.
        var disconnected = injector.state
        disconnected.authentication = .unauthenticated
        _ = injector.transition(to: disconnected)
        XCTAssertEqual(sink.events.last, .modifier(key: .command, isDown: false))
        XCTAssertTrue(injector.held.isEmpty)
    }

    /// Control walks the front app's tabs through the same phases; only the
    /// modifier it holds differs.
    func testTheWalkHoldsWhicheverModifierTheMessageNames() {
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: walk(.begin, .control)), [
            .modifier(key: .control, isDown: true),
            .hotkey(.tab)
        ])
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: walk(.previous, .control)), [
            .hotkey(.shiftTab)
        ])
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: walk(.commit, .control)), [
            .modifier(key: .control, isDown: false)
        ])
    }

    func testCommitAndCancelBothReleaseCommand() {
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: walk(.commit)), [
            .modifier(key: .command, isDown: false)
        ])
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: walk(.cancel)), [
            .hotkey(.escape),
            .modifier(key: .command, isDown: false)
        ])
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .shiftTab), [
            PhysicalKeyTransition(keyCode: 56, isDown: true),
            PhysicalKeyTransition(keyCode: 48, isDown: true),
            PhysicalKeyTransition(keyCode: 48, isDown: false),
            PhysicalKeyTransition(keyCode: 56, isDown: false)
        ])
    }

    func testMissionControlIsControlUpBothWays() {
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .missionControl), [
            PhysicalKeyTransition(keyCode: 59, isDown: true),
            PhysicalKeyTransition(keyCode: 126, isDown: true),
            PhysicalKeyTransition(keyCode: 126, isDown: false),
            PhysicalKeyTransition(keyCode: 59, isDown: false)
        ])
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .appExpose), [
            PhysicalKeyTransition(keyCode: 59, isDown: true),
            PhysicalKeyTransition(keyCode: 125, isDown: true),
            PhysicalKeyTransition(keyCode: 125, isDown: false),
            PhysicalKeyTransition(keyCode: 59, isDown: false)
        ])
        XCTAssertEqual(
            try? SharedInputProtocolAdapter.command(for: .hotkey(HotkeyPayload(action: .appExpose))),
            .hotkey(.appExpose)
        )
        XCTAssertEqual(
            try? SharedInputProtocolAdapter.command(for: .hotkey(HotkeyPayload(action: .missionControl))),
            .hotkey(.missionControl)
        )
        XCTAssertEqual(
            try? SharedInputProtocolAdapter.payload(for: .hotkey(.missionControl)),
            .hotkey(HotkeyPayload(action: .missionControl))
        )
    }

    /// Colemak leaves ZXCVA where QWERTY has them but moves N and T, so a
    /// letter chord has to be posted at the key that types the letter now.
    func testLetterChordsFollowTheActiveLayout() {
        let colemak = StubKeyboardLayout(codes: ["n": 38, "t": 3, "w": 13, "c": 8, "a": 0, "`": 50])
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .newItem, layout: colemak), [
            PhysicalKeyTransition(keyCode: 55, isDown: true),
            PhysicalKeyTransition(keyCode: 38, isDown: true),
            PhysicalKeyTransition(keyCode: 38, isDown: false),
            PhysicalKeyTransition(keyCode: 55, isDown: false)
        ])
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .newTab, layout: colemak), [
            PhysicalKeyTransition(keyCode: 55, isDown: true),
            PhysicalKeyTransition(keyCode: 3, isDown: true),
            PhysicalKeyTransition(keyCode: 3, isDown: false),
            PhysicalKeyTransition(keyCode: 55, isDown: false)
        ])
        // Tab is a key, not a letter, so no layout can move it.
        XCTAssertEqual(
            HotkeyPhysicalSequence.transitions(for: .tab, layout: colemak),
            HotkeyPhysicalSequence.transitions(for: .tab)
        )
    }

    /// A layout that cannot say where a letter is must not silently swallow the
    /// chord; QWERTY is the fallback.
    func testAnUnreadableLayoutFallsBackToQwerty() {
        let empty = StubKeyboardLayout(codes: [:])
        XCTAssertEqual(
            HotkeyPhysicalSequence.transitions(for: .newItem, layout: empty),
            HotkeyPhysicalSequence.transitions(for: .newItem)
        )
    }

    func testSelectionStepsAreShiftAndAnArrow() {
        let expected: [(MacAllowedHotkey, UInt16)] = [
            (.selectLeft, 123),
            (.selectRight, 124),
            (.selectUp, 126),
            (.selectDown, 125)
        ]
        for (hotkey, key) in expected {
            XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: hotkey), [
                PhysicalKeyTransition(keyCode: 56, isDown: true),
                PhysicalKeyTransition(keyCode: key, isDown: true),
                PhysicalKeyTransition(keyCode: key, isDown: false),
                PhysicalKeyTransition(keyCode: 56, isDown: false)
            ], "\(hotkey)")
            let payload = try? SharedInputProtocolAdapter.payload(for: .hotkey(hotkey))
            XCTAssertEqual(
                payload.flatMap { try? SharedInputProtocolAdapter.command(for: $0) },
                .hotkey(hotkey),
                "\(hotkey)"
            )
        }
    }

    /// The picker's four new cells.  Each is a letter chord, so each has to
    /// follow the layout rather than a fixed QWERTY position.
    func testPickerChordsAreCommandLetters() {
        let expected: [(MacAllowedHotkey, [PhysicalKeyTransition])] = [
            (.cut, [
                PhysicalKeyTransition(keyCode: 55, isDown: true),
                PhysicalKeyTransition(keyCode: 7, isDown: true),
                PhysicalKeyTransition(keyCode: 7, isDown: false),
                PhysicalKeyTransition(keyCode: 55, isDown: false)
            ]),
            (.save, [
                PhysicalKeyTransition(keyCode: 55, isDown: true),
                PhysicalKeyTransition(keyCode: 1, isDown: true),
                PhysicalKeyTransition(keyCode: 1, isDown: false),
                PhysicalKeyTransition(keyCode: 55, isDown: false)
            ]),
            (.find, [
                PhysicalKeyTransition(keyCode: 55, isDown: true),
                PhysicalKeyTransition(keyCode: 3, isDown: true),
                PhysicalKeyTransition(keyCode: 3, isDown: false),
                PhysicalKeyTransition(keyCode: 55, isDown: false)
            ]),
            (.previousWindow, [
                PhysicalKeyTransition(keyCode: 55, isDown: true),
                PhysicalKeyTransition(keyCode: 56, isDown: true),
                PhysicalKeyTransition(keyCode: 50, isDown: true),
                PhysicalKeyTransition(keyCode: 50, isDown: false),
                PhysicalKeyTransition(keyCode: 56, isDown: false),
                PhysicalKeyTransition(keyCode: 55, isDown: false)
            ])
        ]
        for (hotkey, transitions) in expected {
            XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: hotkey), transitions, "\(hotkey)")

            let payload = try? SharedInputProtocolAdapter.payload(for: .hotkey(hotkey))
            XCTAssertEqual(
                payload.flatMap { try? SharedInputProtocolAdapter.command(for: $0) },
                .hotkey(hotkey),
                "\(hotkey)"
            )
        }

        // Dvorak keeps ` where QWERTY has it but moves the letters, so each
        // chord has to be posted at the key that types its letter now.
        let dvorak = StubKeyboardLayout(codes: ["x": 7, "s": 41, "f": 15, "`": 50])
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .save, layout: dvorak), [
            PhysicalKeyTransition(keyCode: 55, isDown: true),
            PhysicalKeyTransition(keyCode: 41, isDown: true),
            PhysicalKeyTransition(keyCode: 41, isDown: false),
            PhysicalKeyTransition(keyCode: 55, isDown: false)
        ])
        XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: .find, layout: dvorak), [
            PhysicalKeyTransition(keyCode: 55, isDown: true),
            PhysicalKeyTransition(keyCode: 15, isDown: true),
            PhysicalKeyTransition(keyCode: 15, isDown: false),
            PhysicalKeyTransition(keyCode: 55, isDown: false)
        ])
        // A layout that cannot place the letter still has to produce the chord.
        XCTAssertEqual(
            HotkeyPhysicalSequence.transitions(for: .cut, layout: StubKeyboardLayout(codes: [:])),
            HotkeyPhysicalSequence.transitions(for: .cut)
        )
    }

    /// The picker never reaches the injector as a picker: the cell it commits
    /// is submitted as an ordinary hotkey, so it takes the same policy path.
    func testPickerAndPreviewMessagesAreNotCommands() throws {
        XCTAssertThrowsError(
            try SharedInputProtocolAdapter.command(
                for: .keyPicker(KeyPickerPayload(phase: .commit, cell: .save))
            )
        )

        // Built outside the assertion: a throw from the constructor would
        // otherwise satisfy it without the adapter ever being asked.
        let preview = try TranscriptPreviewPayload(text: "hello")
        XCTAssertThrowsError(
            try SharedInputProtocolAdapter.command(for: .transcriptPreview(preview))
        )
    }

    func testWindowAndTabChordsCarryTheirModifier() {
        let expected: [(MacAllowedHotkey, UInt16, UInt16)] = [
            (.nextWindow, 55, 50),
            (.newItem, 55, 45),
            (.newTab, 55, 17),
            (.closeWindow, 55, 13)
        ]
        for (hotkey, modifier, key) in expected {
            XCTAssertEqual(HotkeyPhysicalSequence.transitions(for: hotkey), [
                PhysicalKeyTransition(keyCode: modifier, isDown: true),
                PhysicalKeyTransition(keyCode: key, isDown: true),
                PhysicalKeyTransition(keyCode: key, isDown: false),
                PhysicalKeyTransition(keyCode: modifier, isDown: false)
            ], "\(hotkey)")
            let payload = try? SharedInputProtocolAdapter.payload(for: .hotkey(hotkey))
            XCTAssertEqual(
                payload.flatMap { try? SharedInputProtocolAdapter.command(for: $0) },
                .hotkey(hotkey),
                "\(hotkey)"
            )
        }
    }

    func testReliableDuplicatesAreAcknowledgedAndWatchdogReleases() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)
        let clock = TestInputClock(now: 10)
        let coordinator = ReliableInputCoordinator(injector: injector, clock: clock)
        let action = ReliableInputAction(actionID: 7, command: .mouseButton(button: .left, isDown: true, clickCount: 1))

        XCTAssertEqual(coordinator.receive(action, at: 10), [.applied(actionID: 7), .acknowledgement(actionID: 7)])
        XCTAssertEqual(coordinator.receive(action, at: 10.1), [.acknowledgement(actionID: 7)])
        XCTAssertEqual(sink.events.filter { $0 == .mouseButton(button: .left, isDown: true, clickCount: 1) }.count, 1)
        XCTAssertEqual(coordinator.poll(at: 10.5), [.watchdogExpired, .released(reason: .heartbeatTimeout)])
        XCTAssertEqual(sink.events.last, .mouseButton(button: .left, isDown: false, clickCount: 1))
        XCTAssertEqual(coordinator.poll(at: 11), [])
    }

    func testRetryTrackerHasFiniteAttemptsAndBoundedQueue() {
        var tracker = ReliableRetryTracker(acknowledgementTimeout: 0.1, maxAttempts: 2, maxPending: 1)
        let action = ReliableInputAction(actionID: 1, command: .mouseButton(button: .left, isDown: true, clickCount: 1))
        XCTAssertTrue(tracker.enqueue(action, at: 0))
        XCTAssertFalse(tracker.enqueue(ReliableInputAction(actionID: 2, command: .mouseButton(button: .right, isDown: true, clickCount: 1)), at: 0))
        XCTAssertEqual(tracker.poll(at: 0.1), [.retry(action, attempt: 2)])
        XCTAssertEqual(tracker.poll(at: 0.2), [.exhausted(action)])
        XCTAssertEqual(tracker.pendingCount, 0)
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

    /// A run of one repeated key reaches the sink whole, so the sink can post
    /// it in a single burst.  This is what a held delete key's word notch
    /// builds, and it is the difference between a word costing about 100 ms and
    /// costing about one.
    func testARepeatedHotkeyReachesTheSinkAsOneRun() {
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: controllablePolicy(), sink: sink)

        XCTAssertEqual(injector.submit(.hotkeyRun(.deleteBackward, times: 7)), .applied)
        XCTAssertEqual(sink.events.count, 1)
        guard case let .hotkeyRun(transitions, times) = sink.events[0] else {
            return XCTFail("expected one run")
        }
        XCTAssertEqual(times, 7)
        XCTAssertEqual(transitions, HotkeyPhysicalSequence.transitions(for: .deleteBackward))
    }

    /// The count is the one number a run carries, so it is the one number the
    /// policy has to bound.
    func testARunWithAnImpossibleCountIsRefused() {
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: controllablePolicy(), sink: sink)
        let limit = InputPolicyLimits().maxHotkeyRun

        XCTAssertEqual(injector.submit(.hotkeyRun(.deleteBackward, times: 0)), .denied(.invalidCommand))
        XCTAssertEqual(injector.submit(.hotkeyRun(.deleteBackward, times: limit + 1)), .denied(.invalidCommand))
        XCTAssertEqual(injector.submit(.hotkeyRun(.deleteBackward, times: limit)), .applied)
        XCTAssertEqual(sink.events.count, 1)
    }

    /// A run is worked out on the Mac and never travels, so the wire has no
    /// shape for it and the adapter must say so rather than guess.
    func testARepeatedHotkeyHasNoWireShape() {
        XCTAssertThrowsError(try SharedInputProtocolAdapter.payload(for: .hotkeyRun(.deleteBackward, times: 3)))
    }
}

private final class TestInputClock: InputSafetyClock {
    var now: TimeInterval
    init(now: TimeInterval) { self.now = now }
}


private func walk(_ phase: TabWalkPhase, _ modifier: HeldModifier = .command) -> TabWalkPayload {
    TabWalkPayload(phase: phase, modifier: modifier)
}

private final class StubKeyboardLayout: KeyboardLayoutLookup, @unchecked Sendable {
    private let codes: [Character: UInt16]

    init(codes: [Character: UInt16]) {
        self.codes = codes
    }

    func keyCode(for character: Character) -> UInt16? {
        codes[character]
    }
}
