import XCTest

final class AppSmokeTests: XCTestCase {
    func testBundleMetadataIsPresent() {
        XCTAssertFalse(Bundle.main.bundleIdentifier?.isEmpty ?? true)
    }
}

