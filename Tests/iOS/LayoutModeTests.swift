import UIKit
import XCTest
@testable import PhoneRemote_iOS

/// The layout mode decides which way the screen faces, so the mode and the
/// orientation lock have to agree.
final class LayoutModeTests: XCTestCase {
    @MainActor
    func testApplyingAMaskStoresIt() {
        InterfaceOrientationLock.apply(.landscape)
        XCTAssertEqual(InterfaceOrientationLock.mask, .landscape)

        InterfaceOrientationLock.apply(.portrait)
        XCTAssertEqual(InterfaceOrientationLock.mask, .portrait)
    }

    func testEachModeFacesItsOwnWay() {
        XCTAssertEqual(RemoteLayoutMode.vertical.orientations, .portrait)
        XCTAssertEqual(RemoteLayoutMode.controller.orientations, .landscape)
    }

    func testTheModesToggleBetweenEachOther() {
        XCTAssertEqual(RemoteLayoutMode.vertical.next, .controller)
        XCTAssertEqual(RemoteLayoutMode.controller.next, .vertical)
    }

    func testTheDragTargetsFollowTheHoldBar() {
        XCTAssertEqual(RemoteLayoutMode.vertical.pushToTalkZoneSides(mirrored: false), .both)
        XCTAssertEqual(RemoteLayoutMode.vertical.pushToTalkZoneSides(mirrored: true), .both)
        XCTAssertEqual(RemoteLayoutMode.controller.pushToTalkZoneSides(mirrored: false), .leading)
        XCTAssertEqual(RemoteLayoutMode.controller.pushToTalkZoneSides(mirrored: true), .trailing)
    }

    func testOneSidedTargetsLeaveTheOtherSideAlone() {
        XCTAssertTrue(PushToTalkZoneSides.leading.includes(.cancelLeading))
        XCTAssertFalse(PushToTalkZoneSides.leading.includes(.cancelTrailing))
        XCTAssertFalse(PushToTalkZoneSides.trailing.includes(.cancelLeading))
        XCTAssertTrue(PushToTalkZoneSides.both.includes(.cancelTrailing))
    }

    func testTheStoredNameRestoresTheMode() {
        XCTAssertEqual(RemoteLayoutMode(rawValue: "controller"), .controller)
    }
}
