import Foundation
import XCTest
@testable import NewMotionShared

final class DeviceSlugTests: XCTestCase {
    private func key(_ seed: UInt8) -> Data { Data(repeating: seed, count: 32) }

    func testNameIsStablePerKeyAndDistinctAcrossKeys() {
        XCTAssertEqual(DeviceSlug.name(forIdentityKey: key(1)), DeviceSlug.name(forIdentityKey: key(1)))
        XCTAssertNotEqual(DeviceSlug.name(forIdentityKey: key(1)), DeviceSlug.name(forIdentityKey: key(2)))
    }

    func testNameIsTwoLowercaseWords() {
        for seed in UInt8(0)...UInt8(64) {
            let parts = DeviceSlug.name(forIdentityKey: key(seed)).split(separator: "-")
            XCTAssertEqual(parts.count, 2)
            XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(("a"..."z").contains) })
        }
    }

    func testNameDerivationDoesNotDrift() {
        // The phone shows this name and the Mac files the phone under it. A
        // change here renames every saved phone on the next release.
        XCTAssertEqual(DeviceSlug.name(forIdentityKey: key(7)), "misty-stork")
    }
}
