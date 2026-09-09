import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// What the picker does to arriving messages. The model under test is never
/// authenticated, so the injector turns every command down and nothing here
/// can move the real cursor or press a real key.
@MainActor
final class OverlayDispatchTests: XCTestCase {
    /// A model whose injector answers to this test: the sink is the only place
    /// the key a commit actually fired can be seen. Startup puts the injector
    /// back to unauthenticated, so control is granted after the model is built.
    private func controllableModel() -> (MacRemoteAppModel, MockInputEventSink) {
        let sink = MockInputEventSink()
        let injector = SafeInputInjector(sink: sink)
        let model = MacRemoteAppModel(injector: injector)
        _ = injector.transition(to: InputControlState(
            authentication: .authenticated,
            accessibility: .granted
        ))
        return (model, sink)
    }

    func testAnOpenPickerDropsCursorPacketsAndCancelFiresNothing() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .begin)))
        XCTAssertEqual(model.lastApplicationMessage, "keyPicker begin")

        // Travel already in flight when the press started reaches nothing:
        // the last word on what happened is still the picker opening.
        try model.dispatchApplication(.pointerDelta(PointerDeltaPayload(deltaX: 7, deltaY: -3)))
        try model.dispatchApplication(.scrollDelta(ScrollDeltaPayload(deltaX: 0, deltaY: 4)))
        try model.dispatchApplication(.motionPointerDelta(MotionPointerDeltaPayload(
            deltaX: 3,
            deltaY: 2,
            sampleRateHz: 60
        )))
        XCTAssertEqual(model.lastApplicationMessage, "keyPicker begin")

        // A cancel closes the card and asks the injector for nothing at all.
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .cancel)))
        XCTAssertEqual(model.lastApplicationMessage, "keyPicker cancel")
        XCTAssertEqual(model.overlay.content, .nothing)

        // And the cursor is moving again.
        try model.dispatchApplication(.pointerDelta(PointerDeltaPayload(deltaX: 7, deltaY: -3)))
        XCTAssertEqual(model.lastApplicationMessage, "pointerDelta blocked")
    }

    func testACommitTakesTheOrdinaryHotkeyPath() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .begin)))
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .commit, cell: .save)))
        // Refused, because this model was never authenticated. What matters is
        // that it was the hotkey path that refused it.
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")
        XCTAssertEqual(model.overlay.content, .nothing)
    }

    /// The commit fires the cell it names, not the last one lit: a highlight
    /// lost on the way costs a stale card, never the wrong shortcut.
    func testACommitFiresTheCellItNamesRatherThanTheLitOne() throws {
        let (model, sink) = controllableModel()
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .begin)))
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .highlight, cell: .copy)))
        XCTAssertEqual(model.overlay.content, .picker(cell: .copy))

        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .commit, cell: .save)))
        // Through the live layout, the same way the injector resolved it: on a
        // non-QWERTY keyboard ⌘S is not the QWERTY key code.
        XCTAssertEqual(sink.events, [.hotkey(HotkeyPhysicalSequence.transitions(
            for: .save,
            layout: ActiveKeyboardLayout.shared
        ))])
        XCTAssertEqual(model.overlay.content, .nothing)
    }

    func testThreePlainDeletesPutTheHintOnTheCard() throws {
        let (model, _) = controllableModel()
        for _ in 0..<3 {
            try model.dispatchApplication(.hotkey(HotkeyPayload(action: .deleteBackward)))
        }
        XCTAssertEqual(model.overlay.content, .hint(MacOverlayPresenter.deleteSlideHint))
    }

    /// Deletes that erased nothing are nobody wishing the gesture were faster.
    func testDeletesThatWereRefusedPaintNoHint() throws {
        let model = MacRemoteAppModel()
        for _ in 0..<3 {
            try model.dispatchApplication(.hotkey(HotkeyPayload(action: .deleteBackward)))
        }
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")
        XCTAssertEqual(model.overlay.content, .nothing)
    }

    /// The watchdog is the only thing that notices a phone which suspended
    /// mid-press, so it has to reach the card and not just the held buttons.
    func testAWatchdogExpiryTakesTheCardDown() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .begin)))
        XCTAssertEqual(model.overlay.content, .picker(cell: nil))

        // Heard from long enough ago that the next poll is past the timeout.
        model.reliableInput.receive(heartbeat: InputHeartbeat(), at: 0)
        model.pollPhone()
        XCTAssertEqual(model.overlay.content, .nothing)
        XCTAssertFalse(model.overlay.isPickerOpen)
    }

    /// Nothing on the card outlives the session it belongs to.
    func testADisconnectTakesTheCardDown() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .begin)))
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .highlight, cell: .undo)))
        XCTAssertEqual(model.overlay.content, .picker(cell: .undo))

        model.clearHandshakeState()
        XCTAssertEqual(model.overlay.content, .nothing)
    }

    /// The unit flip is for the card and nothing else: it presses no key, and
    /// it must not disturb what the press has already taken. A notch is what
    /// erases; this only says which unit the next one will take off.
    func testAUnitChangeLightsTheCardAndInjectsNothing() throws {
        let (model, sink) = controllableModel()
        try model.dispatchApplication(.deleteScrub(
            DeleteScrubPayload(phase: .begin, granularity: .character)
        ))
        // Still inside the open delay, which no timer can cross while this
        // test holds the main actor.
        XCTAssertEqual(model.overlay.content, .nothing)

        try model.dispatchApplication(.deleteScrub(
            DeleteScrubPayload(phase: .unitChanged, granularity: .word)
        ))
        XCTAssertEqual(model.lastApplicationMessage, "deleteScrub unit word")
        XCTAssertEqual(model.overlay.content, .delete(granularity: .word))
        XCTAssertTrue(sink.events.isEmpty)

        try model.dispatchApplication(.deleteScrub(
            DeleteScrubPayload(phase: .end, granularity: .word)
        ))
        XCTAssertEqual(model.overlay.content, .nothing)
        XCTAssertTrue(sink.events.isEmpty)
    }

    /// The card belongs to the press, so a disconnect that abandons the press
    /// has to take it down too.
    func testADisconnectTakesTheDeleteCardDown() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.deleteScrub(
            DeleteScrubPayload(phase: .begin, granularity: .character)
        ))
        try model.dispatchApplication(.deleteScrub(
            DeleteScrubPayload(phase: .unitChanged, granularity: .word)
        ))
        XCTAssertEqual(model.overlay.content, .delete(granularity: .word))

        model.clearHandshakeState()
        XCTAssertEqual(model.overlay.content, .nothing)
    }

    /// The words on the card must not reach the debug snapshot, which is what
    /// `lastApplicationMessage` feeds.
    func testAPreviewLeavesNoTraceInTheDebugState() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.hotkey(HotkeyPayload(action: .copy)))
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")

        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(text: "spoken words")))
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")

        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(phase: .ended, text: "")))
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")
    }

    /// The talk button decides whether the card is up, not the words: a live
    /// preview with none yet is the phone saying it is listening.
    func testTheHoldPutsTheCardUpAndItsEndTakesItDown() throws {
        let model = MacRemoteAppModel()

        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(text: "")))
        XCTAssertEqual(model.overlay.content, .transcript("", armed: .none))

        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(text: "spoken words")))
        XCTAssertEqual(model.overlay.content, .transcript("spoken words", armed: .none))

        // The phrase was typed, but the finger is still down.
        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(text: "")))
        XCTAssertEqual(model.overlay.content, .transcript("", armed: .none))

        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(phase: .ended, text: "")))
        XCTAssertEqual(model.overlay.content, .nothing)
    }

    /// The bar the finger is sitting on rides in with the words, so the Mac's
    /// card says what letting go would do without knowing where the thumb is.
    func testTheArmedBarArrivesWithThePreview() throws {
        let model = MacRemoteAppModel()

        try model.dispatchApplication(
            .transcriptPreview(TranscriptPreviewPayload(text: "spoken words", armed: .send))
        )
        XCTAssertEqual(model.overlay.content, .transcript("spoken words", armed: .send))

        try model.dispatchApplication(
            .transcriptPreview(TranscriptPreviewPayload(text: "spoken words", armed: .cancel))
        )
        XCTAssertEqual(model.overlay.content, .transcript("spoken words", armed: .cancel))

        // The finger backed off the bar and onto the talk button again.
        try model.dispatchApplication(
            .transcriptPreview(TranscriptPreviewPayload(text: "spoken words"))
        )
        XCTAssertEqual(model.overlay.content, .transcript("spoken words", armed: .none))
    }
}
