import UIKit
import XCTest
@testable import PhoneRemote_iOS

/// Sideways, the phone tilts about a different body axis than upright, so the
/// filter has to read the tilt from the axis the screen says is horizontal.
final class MotionOrientationTests: XCTestCase {
    private static let tilt = 0.05

    private func tilt(aboutY orientation: MotionScreenOrientation) -> MotionPointerDelta? {
        var filter = MotionPointerFilter(configuration: MotionFilterConfiguration(screenOrientation: orientation))
        filter.setClutch(active: true)
        XCTAssertNil(filter.process(MotionSample(timestamp: 0, attitude: .identity)))
        let half = Self.tilt / 2
        return filter.process(MotionSample(
            timestamp: 0.01,
            attitude: MotionQuaternion(w: cos(half), x: 0, y: sin(half), z: 0)
        ))
    }

    func testUprightIgnoresARollAboutTheLongAxis() {
        XCTAssertNil(tilt(aboutY: .portrait))
    }

    func testSidewaysReadsTheLongAxisAsTilt() throws {
        let topOnRight = try XCTUnwrap(tilt(aboutY: .landscapeLeft))
        XCTAssertEqual(topOnRight.x, 0)
        XCTAssertLessThan(topOnRight.y, 0)

        let topOnLeft = try XCTUnwrap(tilt(aboutY: .landscapeRight))
        XCTAssertEqual(topOnLeft.x, 0)
        XCTAssertGreaterThan(topOnLeft.y, 0)
    }

    func testTurningAboutTheScreenIsHorizontalEitherWay() {
        let turn = MotionVector3(x: 0, y: 0, z: 0.1)
        for orientation in [MotionScreenOrientation.portrait, .landscapeLeft, .landscapeRight] {
            let motion = orientation.pointerMotion(for: turn)
            XCTAssertEqual(motion.x, -0.1)
            XCTAssertEqual(motion.y, 0)
        }
    }

    func testTheScreenOrientationComesFromTheInterface() {
        XCTAssertEqual(MotionScreenOrientation(UIInterfaceOrientation.landscapeLeft), .landscapeLeft)
        XCTAssertEqual(MotionScreenOrientation(UIInterfaceOrientation.landscapeRight), .landscapeRight)
        XCTAssertEqual(MotionScreenOrientation(UIInterfaceOrientation.portrait), .portrait)
        XCTAssertEqual(MotionScreenOrientation(nil), .portrait)
    }
}
