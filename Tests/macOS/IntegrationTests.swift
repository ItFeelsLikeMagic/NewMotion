import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

final class IntegrationTests: XCTestCase {
    func testFramedProtocolInputReachesSafetySinkAndDisconnectReleasesIt() throws {
        let command = RemoteInputCommand.mouseButton(button: .left, isDown: true)
        let payload = try SharedInputProtocolAdapter.payload(for: command)
        let sessionID = try SessionID(bytes: Array(repeating: 0x41, count: SessionID.byteCount))
        let envelope = ProtocolEnvelope(sessionID: sessionID, sequence: 1, timestampMs: 100, payload: payload)
        let frames = try BLEFragmenter().fragment(
            payload: Data(try ProtocolCodec.encode(envelope)),
            kind: .data,
            reliable: true,
            messageID: 81,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        )
        let reassembler = try BLEReassembler(maximumValueLength: BLEFramingLimits.minimumValueLength)
        var complete: Data?
        for frame in frames {
            if case let .complete(payload, _, _, _) = try reassembler.append(frame) {
                complete = payload
            }
        }
        let decoded = try ProtocolCodec.decode(Array(try XCTUnwrap(complete)))
        let received = try SharedInputProtocolAdapter.command(for: decoded.payload)

        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)
        XCTAssertEqual(injector.submit(received), .applied)
        XCTAssertEqual(sink.events, [.mouseButton(button: .left, isDown: true)])

        var disconnected = injector.state
        disconnected.authentication = .unauthenticated
        _ = injector.transition(to: disconnected)
        XCTAssertEqual(sink.events.last, .mouseButton(button: .left, isDown: false))
    }

    func testMotionPointerDeltaReachesSafetySinkAsPointer() throws {
        let payload = MessagePayload.motionPointerDelta(
            MotionPointerDeltaPayload(deltaX: -4, deltaY: 6, sampleRateHz: 100)
        )
        let command = try SharedInputProtocolAdapter.command(for: payload)
        XCTAssertEqual(command, .pointer(MacPointerDelta(x: -4, y: 6)))

        var state = InputControlState()
        state.authentication = .authenticated
        state.accessibility = .granted
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(policy: InputSafetyStateMachine(state: state), sink: sink)
        XCTAssertEqual(injector.submit(command), .applied)
        XCTAssertEqual(sink.events, [.pointer(delta: MacPointerDelta(x: -4, y: 6))])
    }

    func testAllowlistedTextAndHotkeyRoundTripThroughTheBridge() throws {
        for command in [
            RemoteInputCommand.text("hello"),
            RemoteInputCommand.hotkey(.copy),
            RemoteInputCommand.hotkey(.arrowRight)
        ] {
            let payload = try SharedInputProtocolAdapter.payload(for: command)
            XCTAssertEqual(try SharedInputProtocolAdapter.command(for: payload), command)
        }
    }
}
