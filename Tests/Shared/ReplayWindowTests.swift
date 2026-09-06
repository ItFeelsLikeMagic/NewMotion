import CryptoKit
import Foundation
import XCTest
@testable import NewMotionShared

/// The session accepts a frame that lost a race to a later one, but never the
/// same frame twice and never one older than the window.
final class ReplayWindowTests: XCTestCase {
    private func makeSessions() throws -> (sender: PairingSession, receiver: PairingSession) {
        let key = SymmetricKey(data: Data(repeating: 0x5a, count: 32))
        let sessionID = Data(repeating: 0x11, count: 16)
        return (
            try PairingSession(key: key, sessionID: sessionID),
            try PairingSession(key: key, sessionID: sessionID)
        )
    }

    private func envelopes(_ count: Int, from session: PairingSession) throws -> [Data] {
        try (0..<count).map { index in
            try session.encrypt(plaintext: Data("frame \(index)".utf8), messageType: 2)
        }
    }

    func testOutOfOrderFrameIsStillAccepted() throws {
        let (sender, receiver) = try makeSessions()
        let frames = try envelopes(2, from: sender)
        XCTAssertEqual(try receiver.decrypt(frames[1]).plaintext, Data("frame 1".utf8))
        // The loser of the race used to be thrown away here.
        XCTAssertEqual(try receiver.decrypt(frames[0]).plaintext, Data("frame 0".utf8))
    }

    func testDuplicateInsideTheWindowIsRejected() throws {
        let (sender, receiver) = try makeSessions()
        let frames = try envelopes(3, from: sender)
        _ = try receiver.decrypt(frames[2])
        _ = try receiver.decrypt(frames[0])
        XCTAssertThrowsError(try receiver.decrypt(frames[0])) { error in
            XCTAssertEqual(error as? PairingError, .replayedEnvelope)
        }
        XCTAssertThrowsError(try receiver.decrypt(frames[2])) { error in
            XCTAssertEqual(error as? PairingError, .replayedEnvelope)
        }
        XCTAssertEqual(try receiver.decrypt(frames[1]).plaintext, Data("frame 1".utf8))
    }

    func testFrameOlderThanTheWindowIsRejected() throws {
        let (sender, receiver) = try makeSessions()
        let frames = try envelopes(80, from: sender)
        _ = try receiver.decrypt(frames[79])
        XCTAssertThrowsError(try receiver.decrypt(frames[0])) { error in
            XCTAssertEqual(error as? PairingError, .sequenceRollback)
        }
        // The newest 64 are still inside the window.
        XCTAssertEqual(try receiver.decrypt(frames[16]).plaintext, Data("frame 16".utf8))
    }

    func testFailedTagLeavesTheWindowUntouched() throws {
        let (sender, receiver) = try makeSessions()
        let frames = try envelopes(2, from: sender)
        var tampered = frames[1]
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(try receiver.decrypt(tampered)) { error in
            XCTAssertEqual(error as? PairingError, .authenticationFailed)
        }
        // A forged frame must not retire the sequence the real peer still owes.
        XCTAssertEqual(try receiver.decrypt(frames[1]).plaintext, Data("frame 1".utf8))
        XCTAssertEqual(try receiver.decrypt(frames[0]).plaintext, Data("frame 0".utf8))
    }

    func testLargeForwardJumpClearsTheWindow() throws {
        let (sender, receiver) = try makeSessions()
        let frames = try envelopes(200, from: sender)
        _ = try receiver.decrypt(frames[0])
        _ = try receiver.decrypt(frames[199])
        XCTAssertThrowsError(try receiver.decrypt(frames[0])) { error in
            XCTAssertEqual(error as? PairingError, .sequenceRollback)
        }
        XCTAssertEqual(try receiver.decrypt(frames[150]).plaintext, Data("frame 150".utf8))
    }
}
