import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// What the picker does to arriving messages. The model under test is never
/// authenticated, so the injector turns every command down and nothing here
/// can move the real cursor or press a real key.
@MainActor
final class OverlayDispatchTests: XCTestCase {
    func testAnOpenPickerDropsCursorPacketsAndCancelFiresNothing() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.keyPicker(KeyPickerPayload(phase: .begin)))
        XCTAssertEqual(model.lastApplicationMessage, "keyPicker begin")

        // Travel already in flight when the press started reaches nothing:
        // the last word on what happened is still the picker opening.
        try model.dispatchApplication(.pointerDelta(PointerDeltaPayload(deltaX: 7, deltaY: -3)))
        try model.dispatchApplication(.scrollDelta(ScrollDeltaPayload(deltaX: 0, deltaY: 4)))
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

    func testThreePlainDeletesPutTheHintOnTheCard() throws {
        let model = MacRemoteAppModel()
        for _ in 0..<3 {
            try model.dispatchApplication(.hotkey(HotkeyPayload(action: .deleteBackward)))
        }
        XCTAssertEqual(model.overlay.content, .hint(MacOverlayPresenter.deleteSlideHint))
    }

    /// The words on the card must not reach the debug snapshot, which is what
    /// `lastApplicationMessage` feeds.
    func testAPreviewLeavesNoTraceInTheDebugState() throws {
        let model = MacRemoteAppModel()
        try model.dispatchApplication(.hotkey(HotkeyPayload(action: .copy)))
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")

        try model.dispatchApplication(.transcriptPreview(TranscriptPreviewPayload(text: "spoken words")))
        XCTAssertEqual(model.lastApplicationMessage, "hotkey blocked")
    }
}
