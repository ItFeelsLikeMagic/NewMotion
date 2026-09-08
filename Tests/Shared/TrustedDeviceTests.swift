import Foundation
import XCTest
@testable import NewMotionShared

/// A peer mints a fresh pairing ID for every QR code, so the identity key is
/// the only thing that says two records are the same physical device.
final class TrustedDeviceTests: XCTestCase {
    private func makeManager() -> (TrustedDeviceManager, InMemoryTrustedDeviceStore) {
        let store = InMemoryTrustedDeviceStore()
        return (TrustedDeviceManager(store: store), store)
    }

    func testRePairingTheSamePeerSupersedesTheOldRecord() throws {
        let (trust, store) = makeManager()
        let mac = PairingIdentity()
        let local = trust.newIdentity()

        for _ in 0..<6 {
            _ = try trust.remember(
                deviceID: UUID(),
                displayName: "David's MacBook Pro",
                peerIdentityPublicKey: mac.publicKey,
                localIdentity: local
            )
        }

        XCTAssertEqual(try store.allRecords().count, 1)
        XCTAssertEqual(try trust.list().count, 1)
    }

    func testTwoDifferentPeersBothSurvive() throws {
        let (trust, _) = makeManager()
        let local = trust.newIdentity()

        for _ in 0..<2 {
            _ = try trust.remember(
                deviceID: UUID(),
                displayName: "Mac",
                peerIdentityPublicKey: PairingIdentity().publicKey,
                localIdentity: local
            )
        }

        XCTAssertEqual(try trust.list().count, 2)
    }

    /// Duplicates written before `remember` began superseding them still have
    /// to collapse, or an existing pile stays in the picker forever.
    func testListCollapsesRecordsAlreadyInTheStoreKeepingTheNewest() throws {
        let (trust, store) = makeManager()
        let mac = PairingIdentity()
        let local = trust.newIdentity()
        let newest = UUID()

        try store.save(TrustedDeviceRecord(
            deviceID: UUID(),
            displayName: "Mac",
            peerIdentityPublicKey: mac.publicKey,
            localIdentityPrivateKey: local.rawPrivateKey,
            pairedAt: Date(timeIntervalSince1970: 100)
        ))
        try store.save(TrustedDeviceRecord(
            deviceID: newest,
            displayName: "Mac",
            peerIdentityPublicKey: mac.publicKey,
            localIdentityPrivateKey: local.rawPrivateKey,
            pairedAt: Date(timeIntervalSince1970: 200)
        ))

        let listed = try trust.list()
        XCTAssertEqual(listed.count, 1)
        // The newest pairing ID is the beacon the Mac still scans for.
        XCTAssertEqual(listed.first?.deviceID, newest)
    }

    func testRevokingOneRowDropsEveryRecordForThatPeer() throws {
        let (trust, store) = makeManager()
        let mac = PairingIdentity()
        let local = trust.newIdentity()
        let stale = UUID()

        try store.save(TrustedDeviceRecord(
            deviceID: stale,
            displayName: "Mac",
            peerIdentityPublicKey: mac.publicKey,
            localIdentityPrivateKey: local.rawPrivateKey,
            pairedAt: Date(timeIntervalSince1970: 100)
        ))
        let current = try trust.remember(
            deviceID: UUID(),
            displayName: "Mac",
            peerIdentityPublicKey: mac.publicKey,
            localIdentity: local
        )

        // remember() already dropped the stale row; prove revoke does too.
        try store.save(TrustedDeviceRecord(
            deviceID: stale,
            displayName: "Mac",
            peerIdentityPublicKey: mac.publicKey,
            localIdentityPrivateKey: local.rawPrivateKey,
            pairedAt: Date(timeIntervalSince1970: 100)
        ))
        try trust.revoke(deviceID: current.deviceID)

        XCTAssertTrue(try store.allRecords().isEmpty)
    }

    func testSummaryCarriesTheIdentityKeyTheUICollapsesOn() throws {
        let (trust, _) = makeManager()
        let mac = PairingIdentity()
        let summary = try trust.remember(
            deviceID: UUID(),
            displayName: "Mac",
            peerIdentityPublicKey: mac.publicKey,
            localIdentity: trust.newIdentity()
        )
        XCTAssertEqual(summary.peerIdentityPublicKey, mac.publicKey)
    }
}
