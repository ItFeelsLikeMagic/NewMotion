import Foundation
import XCTest
@testable import PhoneRemote_macOS

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

