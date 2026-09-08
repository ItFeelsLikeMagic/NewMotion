import CryptoKit
import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

/// The phone's choice of Mac, and what it falls back to when a scan fails.
@MainActor
final class TrustedMacSelectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedMacID")
        super.tearDown()
    }

    func testPickingTheMacAlreadyInUseKeepsTheLinkItIsOn() throws {
        let macs = try makeTwoTrustedMacs()
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(link: link, pairingCoordinator: macs.coordinator)

        // Nothing chosen yet, so the picker offers the newest pairing and the
        // phone is already reaching for it.
        XCTAssertNil(model.selectedMacID)
        XCTAssertEqual(model.selectedMac?.deviceID, macs.newer.deviceID)
        XCTAssertEqual(link.beacons, [NewMotionBeacon.uuid(pairingID: macs.newer.deviceID)])
        let stopsBefore = link.stopCount
        let startsBefore = link.startCount

        model.selectMac(macs.newer.deviceID)

        XCTAssertEqual(model.selectedMacID, macs.newer.deviceID)
        XCTAssertEqual(link.stopCount, stopsBefore, "picking the Mac in use must not drop its link")
        XCTAssertEqual(link.startCount, startsBefore)
        XCTAssertEqual(link.beacons, [NewMotionBeacon.uuid(pairingID: macs.newer.deviceID)])
    }

    func testPickingTheOtherMacDropsTheLinkAndAimsAtTheNewOne() throws {
        let macs = try makeTwoTrustedMacs()
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(link: link, pairingCoordinator: macs.coordinator)
        let stopsBefore = link.stopCount
        let startsBefore = link.startCount

        model.selectMac(macs.older.deviceID)

        XCTAssertEqual(model.selectedMacID, macs.older.deviceID)
        XCTAssertEqual(link.stopCount, stopsBefore + 1)
        XCTAssertEqual(link.startCount, startsBefore + 1)
        XCTAssertEqual(link.beacons, [NewMotionBeacon.uuid(pairingID: macs.older.deviceID)])
    }

    func testAFailedScanFallsBackToTheMacThePhoneAlreadyTrusts() async throws {
        let store = InMemoryTrustedDeviceStore()
        let coordinator = try IPhonePairingCoordinator(store: store)
        let trusted = try coordinator.rememberPairedMac(
            deviceID: UUID(),
            displayName: "Trusted Mac",
            peerIdentityPublicKey: PairingIdentity().publicKey
        )
        let link = FakeMessageLink()
        let model = NewMotionFeatureModel(link: link, pairingCoordinator: coordinator)
        let trustedBeacon = NewMotionBeacon.uuid(pairingID: trusted.deviceID)
        XCTAssertEqual(link.beacons, [trustedBeacon])

        let token = try makeToken()
        coordinator.beginOneTimeHandshake(token: token)
        try await settle()
        XCTAssertEqual(link.beacons, [NewMotionBeacon.uuid(pairingID: token.pairingID)])
        let startsBefore = link.startCount

        // A message the link cannot reassemble mid-handshake ends the scan.
        link.onError?(.malformedMessage)
        try await settle()

        XCTAssertEqual(link.beacons, [trustedBeacon], "a failed scan must not leave the phone aimed at nobody")
        XCTAssertEqual(link.startCount, startsBefore + 1)
        XCTAssertEqual(model.trustedMacName, "Trusted Mac")
    }

    // MARK: - Helpers

    /// Two Macs a phone has paired with, oldest first. Trust records collapse
    /// per peer identity key, so each needs its own.
    private func makeTwoTrustedMacs() throws -> (
        coordinator: IPhonePairingCoordinator,
        older: TrustedDeviceSummary,
        newer: TrustedDeviceSummary
    ) {
        let clock = MutableClock(Date())
        let coordinator = try IPhonePairingCoordinator(store: InMemoryTrustedDeviceStore(), clock: clock)
        clock.nowValue = clock.nowValue.addingTimeInterval(-60)
        let older = try coordinator.rememberPairedMac(
            deviceID: UUID(),
            displayName: "Older Mac",
            peerIdentityPublicKey: PairingIdentity().publicKey
        )
        clock.nowValue = clock.nowValue.addingTimeInterval(60)
        let newer = try coordinator.rememberPairedMac(
            deviceID: UUID(),
            displayName: "Newer Mac",
            peerIdentityPublicKey: PairingIdentity().publicKey
        )
        return (coordinator, older, newer)
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

    /// The model answers its link and its coordinator through a main-actor hop.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }
}

private final class MutableClock: PairingClock {
    var nowValue: Date
    init(_ now: Date) { nowValue = now }
    var now: Date { nowValue }
}

private final class FakeMessageLink: MessageLink {
    // Searching, not connected: the handshake hello and its retry timer stay
    // out of the way of what these tests are watching.
    var state: RemoteLinkState = .searching
    var peerName: String?
    var maximumMessageBytes = 512
    var onStateChange: ((RemoteLinkState) -> Void)?
    var onMessage: ((LinkChannel, Data) -> Void)?
    var onReadyToSend: (() -> Void)?
    var onError: ((LinkError) -> Void)?
    private(set) var beacons: [UUID] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func send(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult { .sent }
    func setBeacons(_ beacons: [UUID]) { self.beacons = beacons }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}
