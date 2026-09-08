import CryptoKit
import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The phone noticing on its own that the Mac on the other end has gone.
@MainActor
final class MacSilenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
        super.tearDown()
    }

    func testAQuietMacIsDroppedSoThePhoneAdvertisesAgain() async throws {
        let clock = MutableUptime(1_000)
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(link: link, pairingCoordinator: try trustedCoordinator(), uptime: { clock.value })
        try await connect(link)
        let stops = link.stopCount
        let starts = link.startCount

        clock.value += 5
        model.beat()
        XCTAssertEqual(link.stopCount, stops, "five seconds is a slow Mac, not a dead one")

        clock.value += 6
        model.beat()
        XCTAssertEqual(link.stopCount, stops + 1)
        XCTAssertEqual(link.startCount, starts + 1, "the service goes down and straight back up, so the beacon is lit again")
    }

    func testAnythingTheMacSaysResetsTheClock() async throws {
        let clock = MutableUptime(1_000)
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(link: link, pairingCoordinator: try trustedCoordinator(), uptime: { clock.value })
        try await connect(link)
        let stops = link.stopCount

        clock.value += 8
        // Sealed traffic this phone has no session for still proves the Mac
        // is there.
        link.onMessage?(.data, Data([1, 2, 3]))
        try await settle()

        clock.value += 9
        model.beat()
        XCTAssertEqual(link.stopCount, stops)

        clock.value += 2
        model.beat()
        XCTAssertEqual(link.stopCount, stops + 1)
    }

    func testAQRPairingWaitsForTheMacsUserRatherThanItsAnswer() async throws {
        let clock = MutableUptime(1_000)
        let coordinator = try IPhonePairingCoordinator(store: InMemoryTrustedDeviceStore())
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(link: link, pairingCoordinator: coordinator, uptime: { clock.value })
        coordinator.beginOneTimeHandshake(token: try makeToken())
        try await settle()
        try await connect(link)
        let stops = link.stopCount

        // The Mac's user has the whole life of the code to answer the prompt,
        // and the Mac says nothing until they do.
        clock.value += 60
        model.beat()
        XCTAssertEqual(link.stopCount, stops)
    }

    // MARK: - Helpers

    private func trustedCoordinator() throws -> IPhonePairingCoordinator {
        let coordinator = try IPhonePairingCoordinator(store: InMemoryTrustedDeviceStore())
        _ = try coordinator.rememberPairedMac(
            deviceID: UUID(),
            displayName: "Trusted Mac",
            peerIdentityPublicKey: PairingIdentity().publicKey
        )
        return coordinator
    }

    private func makeToken() throws -> PairingToken {
        try PairingToken(
            macDisplayName: "Scanned Mac",
            macEphemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            oneTimeSecret: Data(repeating: 7, count: 32),
            pairingID: UUID(),
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(119)
        )
    }

    private func connect(_ link: FakeMessageLink) async throws {
        link.state = .connected
        link.onStateChange?(.connected)
        try await settle()
    }

    /// The model answers its link and its coordinator through a main-actor hop.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }
}

private final class MutableUptime {
    var value: TimeInterval
    init(_ value: TimeInterval) { self.value = value }
}
