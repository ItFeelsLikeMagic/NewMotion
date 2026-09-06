import Foundation
import XCTest
@testable import NewMotionShared

final class BeaconTests: XCTestCase {
    func testBeaconIsStablePerPairingAndDistinctAcrossPairings() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(NewMotionBeacon.uuid(pairingID: first), NewMotionBeacon.uuid(pairingID: first))
        XCTAssertNotEqual(NewMotionBeacon.uuid(pairingID: first), NewMotionBeacon.uuid(pairingID: second))
        XCTAssertNotEqual(NewMotionBeacon.uuid(pairingID: first), first)
        XCTAssertNotEqual(NewMotionBeacon.uuid(pairingID: first), NewMotionGATT.serviceUUID)
    }

    func testBeaconReadsAsARandomUUID() {
        let beacon = NewMotionBeacon.uuid(pairingID: UUID()).uuid
        XCTAssertEqual(beacon.6 & 0xF0, 0x40)
        XCTAssertEqual(beacon.8 & 0xC0, 0x80)
    }

    func testBeaconDerivationDoesNotDrift() {
        let id = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
        // Both apps must agree across releases; a change here strands every
        // paired phone until it scans a new code.
        XCTAssertEqual(NewMotionBeacon.uuid(pairingID: id).uuidString, "3BB1DDB0-7592-4D59-B5C9-F60B66253012")
    }
}
