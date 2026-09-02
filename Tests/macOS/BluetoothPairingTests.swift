import Foundation
import CryptoKit
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

final class BluetoothPairingTests: XCTestCase {
    func testCentralDiscoversByServiceAndReachesReadyOnlyAfterSubscriptions() {
        let adapter = FakeCentralAdapter()
        let transport = MacBLECentralTransport(adapter: adapter)
        transport.start()
        XCTAssertEqual(transport.state, .scanning)

        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        XCTAssertEqual(transport.state, .connecting)
        XCTAssertEqual(transport.visiblePeripheral, peripheral)
        adapter.emitConnected(peripheral.identifier)
        XCTAssertEqual(transport.state, .discovering)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        XCTAssertEqual(transport.state, .subscribing)
        adapter.emitCharacteristics(peripheral.identifier, serviceUUID: PhoneRemoteGATT.serviceUUID, characteristics: PhoneRemoteGATT.allCharacteristicUUIDs)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID)
        XCTAssertEqual(transport.state, .subscribing)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        XCTAssertEqual(transport.visiblePeripheral, peripheral)
        XCTAssertEqual(transport.maximumWriteValueLength, BLEFramingLimits.minimumValueLength)
        XCTAssertTrue(transport.send(Data([1]), on: .data))
        XCTAssertEqual(adapter.writes.count, 1)
        XCTAssertEqual(adapter.writes.first?.1, PhoneRemoteGATT.macToPhoneDataUUID)
    }

    func testCentralRejectsMalformedServiceAndCleansConnection() {
        let adapter = FakeCentralAdapter()
        let transport = MacBLECentralTransport(adapter: adapter)
        transport.start()
        let peripheralID = UUID()
        adapter.emitDiscover(BLEDiscoveredPeripheral(identifier: peripheralID, name: nil))
        adapter.emitConnected(peripheralID)
        adapter.emitServices(peripheralID, services: [UUID()])
        XCTAssertEqual(transport.state, .scanning)
        XCTAssertNil(transport.connectedPeripheral)
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

    func testCentralRescansAfterReadyDisconnect() {
        let adapter = FakeCentralAdapter()
        let transport = MacBLECentralTransport(adapter: adapter)
        transport.start()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(
            peripheral.identifier,
            serviceUUID: PhoneRemoteGATT.serviceUUID,
            characteristics: PhoneRemoteGATT.allCharacteristicUUIDs
        )
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        XCTAssertEqual(adapter.scanCount, 1)

        adapter.emitDisconnected(peripheral.identifier)
        XCTAssertEqual(transport.state, .scanning)
        XCTAssertEqual(adapter.scanCount, 2)
        XCTAssertNil(transport.connectedPeripheral)
    }

    func testReliableWritesWaitForCompletionBeforeTheNextFrame() {
        let adapter = FakeCentralAdapter()
        let transport = MacBLECentralTransport(adapter: adapter)
        transport.start()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(
            peripheral.identifier,
            serviceUUID: PhoneRemoteGATT.serviceUUID,
            characteristics: PhoneRemoteGATT.allCharacteristicUUIDs
        )
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: PhoneRemoteGATT.phoneToMacControlUUID)

        XCTAssertTrue(transport.send(Data([1]), on: .control, reliable: true))
        XCTAssertTrue(transport.send(Data([2]), on: .control, reliable: true))
        XCTAssertEqual(adapter.writes.count, 1)
        XCTAssertEqual(transport.queuedWriteCount, 1)
        adapter.emitWriteComplete()
        XCTAssertEqual(adapter.writes.count, 2)
        XCTAssertEqual(transport.queuedWriteCount, 0)
        XCTAssertEqual(adapter.writes.map(\.0), [Data([1]), Data([2])])
    }

    func testCentralWritesControlDuringSubscribe() {
        let adapter = FakeCentralAdapter()
        let transport = MacBLECentralTransport(adapter: adapter)
        transport.start()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [PhoneRemoteGATT.serviceUUID])
        adapter.emitCharacteristics(
            peripheral.identifier,
            serviceUUID: PhoneRemoteGATT.serviceUUID,
            characteristics: PhoneRemoteGATT.allCharacteristicUUIDs
        )
        XCTAssertEqual(transport.state, .subscribing)
        XCTAssertTrue(transport.send(Data([9]), on: .control, reliable: true))
        XCTAssertEqual(adapter.writes.first?.1, PhoneRemoteGATT.macToPhoneControlUUID)
    }

    func testCentralConnectsAlreadyConnectedPeripheralOnStart() {
        let adapter = FakeCentralAdapter()
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.preconnected = [peripheral]
        let transport = MacBLECentralTransport(adapter: adapter)
        transport.start()
        XCTAssertEqual(transport.state, .connecting)
        XCTAssertEqual(transport.visiblePeripheral, peripheral)
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
    var onCharacteristicsDiscovered: ((UUID, UUID, Set<UUID>, Error?) -> Void)?
    var onNotificationState: ((UUID, UUID, Bool, Error?) -> Void)?
    var onValue: ((UUID, UUID, Data?, Error?) -> Void)?
    var onReadyToWriteWithoutResponse: (() -> Void)?
    var onWriteComplete: ((Error?) -> Void)?
    var writes: [(Data, UUID, BLEWriteType)] = []
    var scanCount = 0
    var connectCount = 0
    var preconnected: [BLEDiscoveredPeripheral] = []

    func scan(for serviceUUID: UUID) { scanCount += 1 }
    func stopScan() {}
    func connectedPeripherals(for serviceUUID: UUID) -> [BLEDiscoveredPeripheral] { preconnected }
    func connect(peripheralID: UUID) { connectCount += 1 }
    func cancelConnection(peripheralID: UUID) {}
    func discoverServices(peripheralID: UUID, serviceUUID: UUID) {}
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
    func emitWriteComplete(error: Error? = nil) { onWriteComplete?(error) }
}
