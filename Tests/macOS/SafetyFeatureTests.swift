import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

final class SafetyFeatureTests: XCTestCase {
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

    func testAppSwitcherHoldsCommandUntilCommitAndReleasesItOnDisconnect() {
        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)

        for command in SharedInputProtocolAdapter.commands(for: .begin) {
            XCTAssertEqual(injector.submit(command), .applied)
        }
        XCTAssertEqual(sink.events, [
            .modifier(key: .command, isDown: true),
            .hotkey(HotkeyPhysicalSequence.transitions(for: .tab))
        ])
        XCTAssertTrue(injector.held.modifiers.contains(.command))

        for command in SharedInputProtocolAdapter.commands(for: .previous) {
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

    func testCommitAndCancelBothReleaseCommand() {
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: .commit), [
            .modifier(key: .command, isDown: false)
        ])
        XCTAssertEqual(SharedInputProtocolAdapter.commands(for: .cancel), [
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
}

private final class TestInputClock: InputSafetyClock {
    var now: TimeInterval
    init(now: TimeInterval) { self.now = now }
}

