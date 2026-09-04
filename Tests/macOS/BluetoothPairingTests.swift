import Foundation
import CryptoKit
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

final class BluetoothPairingTests: XCTestCase {
    func testLinkConnectsByServiceAndOnlyReportsConnectedAfterSubscriptions() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        link.start()
        XCTAssertEqual(link.state, .searching)

        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        XCTAssertEqual(link.state, .connecting)
        XCTAssertEqual(link.peerName, "Phone")
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(peripheral.identifier, serviceUUID: PhoneRemoteGATT.serviceUUID, characteristics: PhoneRemoteGATT.allCharacteristicUUIDs)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID)
        XCTAssertEqual(link.state, .connecting)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(link.state, .connected)
        XCTAssertEqual(link.send(Data([1]), on: .data, delivery: .unreliableQueued), .sent)
        XCTAssertEqual(adapter.writes.count, 1)
        XCTAssertEqual(adapter.writes.first?.1, PhoneRemoteGATT.macToPhoneDataUUID)
    }

    func testLinkCutsAMessageUpAndPutsOneBackTogether() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        let peripheral = bringLinkToConnected(link, adapter: adapter)
        var received: [(LinkChannel, Data)] = []
        link.onMessage = { received.append(($0, $1)) }

        // The fake adapter offers the 20-byte minimum, so each frame carries
        // four payload bytes behind the sixteen-byte header.
        let message = Data(repeating: 7, count: 30)
        XCTAssertEqual(link.send(message, on: .data, delivery: .unreliableQueued), .sent)
        XCTAssertEqual(adapter.writes.count, 8)

        for frame in adapter.writes.map(\.0) {
            adapter.emitValue(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID, data: frame)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, .data)
        XCTAssertEqual(received.first?.1, message)
    }

    func testLinkRefusesWhatItCannotCarry() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        link.start()
        XCTAssertEqual(link.send(Data([1]), on: .data, delivery: .unreliableQueued), .notConnected)

        bringLinkToConnected(link, adapter: adapter)
        let oversized = Data(repeating: 0, count: link.maximumMessageBytes + 1)
        XCTAssertEqual(link.send(oversized, on: .data, delivery: .unreliableQueued), .tooLarge)
        XCTAssertTrue(adapter.writes.isEmpty)
    }

    func testLinkRediscoversWhenThePhoneRepublishesItsService() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        let peripheral = bringLinkToConnected(link, adapter: adapter)
        let discoveries = adapter.discoverServicesCount

        adapter.emitServicesInvalidated(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])

        XCTAssertEqual(link.state, .connecting)
        XCTAssertEqual(adapter.discoverServicesCount, discoveries + 1)
        XCTAssertTrue(adapter.cancelledConnections.isEmpty)
        XCTAssertEqual(link.peerName, "Phone")

        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(peripheral.identifier, serviceUUID: PhoneRemoteGATT.serviceUUID, characteristics: PhoneRemoteGATT.allCharacteristicUUIDs)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(link.state, .connected)
    }

    func testLinkIgnoresInvalidationOfAnUnrelatedService() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        let peripheral = bringLinkToConnected(link, adapter: adapter)

        adapter.emitServicesInvalidated(peripheral.identifier, services: [UUID()])
        XCTAssertEqual(link.state, .connected)
    }

    func testLinkGivesUpOnAPeerThatNeverFinishesConnecting() {
        let adapter = FakeCentralAdapter()
        var clock = Date(timeIntervalSince1970: 0)
        let link = BLEMessageLink(adapter: adapter, connectionTimeout: 5, now: { clock })
        var failures: [LinkError] = []
        link.onError = { failures.append($0) }
        link.start()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        XCTAssertEqual(link.state, .connecting)

        clock.addTimeInterval(4)
        link.tick()
        XCTAssertEqual(link.state, .connecting)

        clock.addTimeInterval(2)
        link.tick()
        XCTAssertEqual(failures, [.peerNotFound])
        XCTAssertEqual(adapter.cancelledConnections, [peripheral.identifier])
        XCTAssertEqual(link.state, .searching)
    }

    @discardableResult
    private func bringLinkToConnected(
        _ link: BLEMessageLink,
        adapter: FakeCentralAdapter
    ) -> BLEDiscoveredPeripheral {
        link.start()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(peripheral.identifier, serviceUUID: PhoneRemoteGATT.serviceUUID, characteristics: PhoneRemoteGATT.allCharacteristicUUIDs)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(link.state, .connected)
        return peripheral
    }

    func testLinkRejectsAPhoneWithoutTheServiceAndScansAgain() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        var failures: [LinkError] = []
        link.onError = { failures.append($0) }
        link.start()
        let peripheralID = UUID()
        adapter.emitDiscover(BLEDiscoveredPeripheral(identifier: peripheralID, name: nil))
        adapter.emitConnected(peripheralID)
        adapter.emitServices(peripheralID, services: [UUID()])
        XCTAssertEqual(link.state, .searching)
        XCTAssertEqual(failures, [.setupFailed("the phone is not offering Phone Remote")])
        XCTAssertNil(link.peerName)
        XCTAssertEqual(adapter.scanCount, 2)
    }

    func testMacOfferExpiresAndCancellationClearsVisibleMaterial() throws {
        let clock = MutablePairingClock(Date(timeIntervalSince1970: 100))
        let controller = MacPairingOfferController(clock: clock)
        let offer = try controller.issue(displayName: "Mac", lifetime: 2)
        XCTAssertEqual(controller.state, .active(expiresAt: offer.token.expiresAt))
        XCTAssertNotNil(controller.activeQRText)
        clock.nowValue = clock.now.addingTimeInterval(2)
        controller.tick()
        XCTAssertEqual(controller.state, .expired)
        XCTAssertNil(controller.activeQRText)
        XCTAssertNil(controller.activeExpiry)

        _ = try controller.issue(displayName: "Mac", lifetime: 10)
        controller.cancel()
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertNil(controller.activeQRText)
    }

    func testCoordinatorBridgesOneTimeOfferAndPersistsAuthenticatedPhone() throws {
        let store = InMemoryTrustedDeviceStore()
        let coordinator = try MacPairingCoordinator(store: store)
        let offer = try coordinator.issueOffer(displayName: "Mac", lifetime: 60)
        let phoneIdentity = PairingIdentity()
        let client = try PairingHandshakeClient(
            mode: .oneTime(offer.token),
            identity: phoneIdentity,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let server = try coordinator.makeOneTimeServer(pairingID: offer.token.pairingID)
        let serverHello = try server.accept(clientHelloData: client.hello)
        let clientResult = try client.accept(serverHelloData: serverHello.response)
        let serverResult = try server.accept(clientFinishData: clientResult.finish)

        let summary = try coordinator.rememberPairedPhone(
            deviceID: offer.token.pairingID,
            displayName: "Phone",
            peerIdentityPublicKey: serverResult.peerIdentityPublicKey
        )
        XCTAssertEqual(summary.displayName, "Phone")
        XCTAssertEqual(coordinator.trustedDevices, [summary])
        let stored = try XCTUnwrap(try store.record(for: offer.token.pairingID))
        XCTAssertEqual(stored.peerIdentityPublicKey, phoneIdentity.publicKey)
        XCTAssertEqual(stored.localIdentityPrivateKey, coordinator.identity.rawPrivateKey)
        XCTAssertEqual(clientResult.result.session.sessionID, serverResult.session.sessionID)
    }

    func testCoordinatorReconnectsWithoutQRAndRejectsUnknownPhone() throws {
        let store = InMemoryTrustedDeviceStore()
        let mac = try MacPairingCoordinator(store: store)
        let offer = try mac.issueOffer(displayName: "Mac", lifetime: 60)
        let phoneIdentity = PairingIdentity()
        let client = try PairingHandshakeClient(
            mode: .oneTime(offer.token),
            identity: phoneIdentity,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let server = try mac.makeOneTimeServer(pairingID: offer.token.pairingID)
        let serverHello = try server.accept(clientHelloData: client.hello)
        let clientResult = try client.accept(serverHelloData: serverHello.response)
        let serverResult = try server.accept(clientFinishData: clientResult.finish)
        _ = try mac.rememberPairedPhone(
            deviceID: offer.token.pairingID,
            displayName: "Phone",
            peerIdentityPublicKey: serverResult.peerIdentityPublicKey
        )
        let firstSession = clientResult.result.session.sessionID

        let relaunched = try MacPairingCoordinator(store: store)
        XCTAssertEqual(relaunched.identity.publicKey, mac.identity.publicKey)
        XCTAssertEqual(relaunched.trustedDevices.count, 1)
        let reconnectServer = try relaunched.makeHandshakeServer(pairingID: offer.token.pairingID)
        let reconnectClient = try PairingHandshakeClient(
            mode: .trusted(
                deviceID: offer.token.pairingID,
                peerIdentityPublicKey: relaunched.identity.publicKey
            ),
            identity: phoneIdentity,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let hello2 = try reconnectServer.accept(clientHelloData: reconnectClient.hello)
        let client2 = try reconnectClient.accept(serverHelloData: hello2.response)
        let server2 = try reconnectServer.accept(clientFinishData: client2.finish)
        XCTAssertEqual(client2.result.session.sessionID, server2.session.sessionID)
        XCTAssertNotEqual(client2.result.session.sessionID, firstSession)

        let unknown = try PairingHandshakeClient(
            mode: .trusted(
                deviceID: offer.token.pairingID,
                peerIdentityPublicKey: relaunched.identity.publicKey
            ),
            identity: PairingIdentity(),
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let rejectServer = try relaunched.makeHandshakeServer(pairingID: offer.token.pairingID)
        XCTAssertThrowsError(try rejectServer.accept(clientHelloData: unknown.hello))
    }

    func testKeychainStoreEnumeratesRecordsOnMacOS() throws {
        try skipUnlessKeychainTestsRequested()
        let service = "com.example.phoneremote.tests.\(UUID().uuidString)"
        let store = KeychainTrustedDeviceStore(service: service)
        defer { try? store.deleteAll() }

        let localIdentity = PairingIdentity()
        let peerIdentity = PairingIdentity()
        let record = try TrustedDeviceRecord(
            deviceID: UUID(),
            displayName: "Phone",
            peerIdentityPublicKey: peerIdentity.publicKey,
            localIdentityPrivateKey: localIdentity.rawPrivateKey,
            pairedAt: Date(timeIntervalSince1970: 123)
        )

        try store.save(record)
        let second = try TrustedDeviceRecord(
            deviceID: UUID(),
            displayName: "Phone Two",
            peerIdentityPublicKey: PairingIdentity().publicKey,
            localIdentityPrivateKey: PairingIdentity().rawPrivateKey,
            pairedAt: Date(timeIntervalSince1970: 124)
        )
        try store.save(second)
        XCTAssertEqual(try store.allRecords(), [record, second])
        XCTAssertEqual(try store.record(for: record.deviceID), record)
        try store.delete(deviceID: record.deviceID)
        XCTAssertEqual(try store.allRecords(), [second])
    }

    func testMacPairingCoordinatorStartsWithEmptyKeychain() throws {
        try skipUnlessKeychainTestsRequested()
        let service = "com.example.phoneremote.tests.\(UUID().uuidString)"
        let store = KeychainTrustedDeviceStore(service: service)
        defer { try? store.deleteAll() }

        let coordinator = try MacPairingCoordinator(store: store)
        let offer = try coordinator.issueOffer(displayName: "Mac", lifetime: 60)
        XCTAssertEqual(offer.token.macDisplayName, "Mac")
        XCTAssertTrue(coordinator.trustedDevices.isEmpty)
    }

    func testMacPairingProgressSeparatesBleReadyFromAuthenticatedPairing() {
        XCTAssertFalse(MacPairingProgress.connected(deviceName: "Phone").isAuthenticated)
        XCTAssertTrue(MacPairingProgress.paired(deviceName: "Phone").isAuthenticated)
        XCTAssertEqual(MacPairingProgress.authenticating(deviceName: "Phone").title, "Authenticating Phone")
    }

    func testLinkRescansAfterAConnectedPeerDisconnects() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        var failures: [LinkError] = []
        let peripheral = bringLinkToConnected(link, adapter: adapter)
        link.onError = { failures.append($0) }
        XCTAssertEqual(adapter.scanCount, 1)

        adapter.emitDisconnected(peripheral.identifier)
        XCTAssertEqual(failures, [.peerDisconnected])
        XCTAssertEqual(link.state, .searching)
        XCTAssertEqual(adapter.scanCount, 2)
        XCTAssertNil(link.peerName)
    }

    func testReliableWritesWaitForCompletionBeforeTheNextFrame() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        bringLinkToConnected(link, adapter: adapter)

        XCTAssertEqual(link.send(Data([1]), on: .control, delivery: .reliable), .sent)
        XCTAssertEqual(link.send(Data([2]), on: .control, delivery: .reliable), .sent)
        XCTAssertEqual(adapter.writes.count, 1)
        adapter.emitWriteComplete()
        XCTAssertEqual(adapter.writes.count, 2)
        XCTAssertEqual(adapter.writes.map { $0.0.suffix(1) }, [Data([1]), Data([2])])
    }

    func testLinkWritesControlBeforeTheSubscriptionsFinish() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        link.start()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(
            peripheral.identifier,
            serviceUUID: PhoneRemoteGATT.serviceUUID,
            characteristics: PhoneRemoteGATT.allCharacteristicUUIDs
        )
        XCTAssertEqual(link.state, .connecting)
        XCTAssertEqual(link.send(Data([9]), on: .control, delivery: .reliable), .sent)
        XCTAssertEqual(adapter.writes.first?.1, PhoneRemoteGATT.macToPhoneControlUUID)
    }

    func testLinkConnectsAPeripheralTheSystemAlreadyHoldsOnStart() {
        let adapter = FakeCentralAdapter()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.preconnected = [peripheral]
        let link = BLEMessageLink(adapter: adapter)
        link.start()
        XCTAssertEqual(link.state, .connecting)
        XCTAssertEqual(link.peerName, "Phone")
        XCTAssertEqual(adapter.connectCount, 1)
    }

    func testLinkTickAdoptsPeripheralTheSystemConnectedWhileScanning() {
        let adapter = FakeCentralAdapter()
        let link = BLEMessageLink(adapter: adapter)
        link.start()
        XCTAssertEqual(link.state, .searching)
        link.tick()
        XCTAssertEqual(adapter.connectCount, 0)

        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.preconnected = [peripheral]
        link.tick()
        XCTAssertEqual(link.state, .connecting)
        XCTAssertEqual(link.peerName, "Phone")
        XCTAssertEqual(adapter.connectCount, 1)
    }
}

private final class MutablePairingClock: PairingClock {
    var nowValue: Date
    init(_ now: Date) { nowValue = now }
    var now: Date { nowValue }
}

private final class FakeCentralAdapter: MacCentralManagerAdapter {
    var state: BLEPeripheralManagerState = .poweredOn
    var onStateChange: ((BLEPeripheralManagerState) -> Void)?
    var onDiscoverPeripheral: ((BLEDiscoveredPeripheral) -> Void)?
    var onConnected: ((UUID) -> Void)?
    var onConnectionFailed: ((UUID, Error?) -> Void)?
    var onDisconnected: ((UUID, Error?) -> Void)?
    var onServicesDiscovered: ((UUID, Set<UUID>, Error?) -> Void)?
    var onServicesInvalidated: ((UUID, Set<UUID>) -> Void)?
    var onCharacteristicsDiscovered: ((UUID, UUID, Set<UUID>, Error?) -> Void)?
    var onNotificationState: ((UUID, UUID, Bool, Error?) -> Void)?
    var onValue: ((UUID, UUID, Data?, Error?) -> Void)?
    var onReadyToWriteWithoutResponse: (() -> Void)?
    var onWriteComplete: ((Error?) -> Void)?
    var writes: [(Data, UUID, BLEWriteType)] = []
    var scanCount = 0
    var connectCount = 0
    var stopScanCount = 0
    var cancelledConnections: [UUID] = []
    var discoverServicesCount = 0
    var preconnected: [BLEDiscoveredPeripheral] = []

    func scan(for serviceUUID: UUID) { scanCount += 1 }
    func stopScan() { stopScanCount += 1 }
    func connectedPeripherals(for serviceUUID: UUID) -> [BLEDiscoveredPeripheral] { preconnected }
    func connect(peripheralID: UUID) { connectCount += 1 }
    func cancelConnection(peripheralID: UUID) { cancelledConnections.append(peripheralID) }
    func discoverServices(peripheralID: UUID, serviceUUID: UUID) { discoverServicesCount += 1 }
    func discoverCharacteristics(peripheralID: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID]) {}
    func subscribe(peripheralID: UUID, characteristicUUID: UUID) {}
    @discardableResult
    func write(_ data: Data, peripheralID: UUID, characteristicUUID: UUID, type: BLEWriteType) -> Bool {
        writes.append((data, characteristicUUID, type))
        return true
    }
    func maximumWriteValueLength(peripheralID: UUID, characteristicUUID: UUID) -> Int { 20 }

    func emitDiscover(_ peripheral: BLEDiscoveredPeripheral) { onDiscoverPeripheral?(peripheral) }
    func emitConnected(_ id: UUID) { onConnected?(id) }
    func emitServices(_ id: UUID, services: Set<UUID>) { onServicesDiscovered?(id, services, nil) }
    func emitCharacteristics(_ id: UUID, serviceUUID: UUID, characteristics: Set<UUID>) { onCharacteristicsDiscovered?(id, serviceUUID, characteristics, nil) }
    func emitNotification(_ id: UUID, characteristicUUID: UUID) { onNotificationState?(id, characteristicUUID, true, nil) }
    func emitDisconnected(_ id: UUID) { onDisconnected?(id, nil) }
    func emitServicesInvalidated(_ id: UUID, services: Set<UUID>) { onServicesInvalidated?(id, services) }
    func emitValue(_ id: UUID, characteristicUUID: UUID, data: Data) { onValue?(id, characteristicUUID, data, nil) }
    func emitWriteComplete(error: Error? = nil) { onWriteComplete?(error) }
}

/// Login-Keychain reads and writes make macOS prompt the user on every
/// unsigned rebuild, so the tests that hit the real Keychain run only when
/// somebody is at the machine to approve them.
extension XCTestCase {
    func skipUnlessKeychainTestsRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        // xcodebuild forwards TEST_RUNNER_-prefixed variables to the test host.
        let requested = environment["PHONE_REMOTE_KEYCHAIN_TESTS"] == "1"
            || environment["TEST_RUNNER_PHONE_REMOTE_KEYCHAIN_TESTS"] == "1"
        try XCTSkipUnless(
            requested,
            "Set PHONE_REMOTE_KEYCHAIN_TESTS=1 to run Keychain tests; they need manual approval."
        )
    }
}
