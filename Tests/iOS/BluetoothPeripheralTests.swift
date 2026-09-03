import CoreBluetooth
import Foundation
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

final class BluetoothPeripheralTests: XCTestCase {
    func testPeripheralWaitsForForegroundAndPoweredOnBeforeAdvertising() {
        let adapter = FakePeripheralAdapter(state: .poweredOff)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)

        transport.setForeground(true)
        XCTAssertEqual(transport.state, .waitingForBluetooth)
        XCTAssertTrue(adapter.published.isEmpty)
        XCTAssertTrue(adapter.advertisedService == nil)

        adapter.state = .poweredOn
        adapter.onStateChange?(.poweredOn)
        XCTAssertEqual(transport.state, .publishing)
        XCTAssertEqual(adapter.published.map(\.uuid), [PhoneRemoteGATT.serviceUUID])
        XCTAssertNil(adapter.advertisedService)

        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.advertisedService, PhoneRemoteGATT.serviceUUID)
    }

    func testPeripheralRequiresBothDataSubscriptionsForReady() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)

        let subscriber = "mac-test"
        adapter.emitSubscribe(subscriber, characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        XCTAssertEqual(transport.state, .connected)
        adapter.emitSubscribe(subscriber, characteristic: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        XCTAssertEqual(transport.subscriberIDs, Set([subscriber]))

        transport.setForeground(false)
        XCTAssertEqual(transport.state, .stopped)
        XCTAssertTrue(transport.subscriberIDs.isEmpty)
        XCTAssertTrue(adapter.stopAdvertisingCalled)
    }

    func testPeripheralQueueIsBoundedAndDisconnectClearsFrames() {
        let adapter = FakePeripheralAdapter(state: .poweredOn, updateResult: false)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter, queueLimit: 2)
        var queueFull: [BLETransportChannel] = []
        transport.onQueueFull = { queueFull.append($0) }
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)

        XCTAssertEqual(transport.send(Data([1]), on: .data), .queued)
        XCTAssertEqual(transport.send(Data([2]), on: .data), .queued)
        XCTAssertEqual(transport.send(Data([3]), on: .data), .queueFull)
        XCTAssertEqual(queueFull, [.data])

        transport.stop()
        XCTAssertEqual(transport.queuedFrameCount, 0)
        XCTAssertTrue(transport.subscriberIDs.isEmpty)
    }

    func testUnreliableSendDropsInsteadOfQueueing() {
        let adapter = FakePeripheralAdapter(state: .poweredOn, updateResult: false)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter, queueLimit: 2)
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacControlUUID)

        XCTAssertEqual(transport.send(Data([1]), on: .data, enqueue: false), .queueFull)
        XCTAssertEqual(transport.queuedFrameCount, 0)
        XCTAssertEqual(transport.send(Data([2]), on: .data, enqueue: true), .queued)
        XCTAssertEqual(transport.queuedFrameCount, 1)
    }

    func testQueueCapacityCountsFreeSlotsOnlyWhenReady() {
        let adapter = FakePeripheralAdapter(state: .poweredOn, updateResult: false)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter, queueLimit: 2)
        XCTAssertEqual(transport.queueCapacity(on: .data), 0)
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.queueCapacity(on: .data), 2)
        XCTAssertEqual(transport.send(Data([1]), on: .data), .queued)
        XCTAssertEqual(transport.queueCapacity(on: .data), 1)
        XCTAssertEqual(transport.queueCapacity(on: .control), 2)
    }

    func testAdvertisingStartErrorDoesNotTearDownALiveBeacon() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        var errors = 0
        transport.onTransportError = { _ in errors += 1 }
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)

        adapter.emitAdvertisingStarted(error: BLEFramingError.invalidFlags)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)
    }

    func testPulseDoesNotRestartALiveAdvertisement() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)

        transport.pulseAdvertising()
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)

        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        transport.pulseAdvertising()
        XCTAssertEqual(adapter.startAdvertisingCount, 1)
        XCTAssertEqual(transport.state, .ready)
    }

    func testPulseRestartsAdvertisingAfterAStop() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        transport.setForeground(false)
        XCTAssertEqual(transport.state, .stopped)

        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 2)
    }

    func testPulseDoesNotRepublishWhileServiceIsPublishing() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setForeground(true)
        XCTAssertEqual(transport.state, .publishing)
        XCTAssertEqual(adapter.published.count, 1)

        transport.pulseAdvertising()
        XCTAssertEqual(transport.state, .publishing)
        XCTAssertEqual(adapter.published.count, 1)
        XCTAssertFalse(adapter.stopAdvertisingCalled)
    }

    func testForegroundRefreshDoesNotDropAReadyCentral() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: PhoneRemoteGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        let advertised = adapter.startAdvertisingCount

        transport.setForeground(true)
        XCTAssertEqual(transport.state, .ready)
        XCTAssertEqual(adapter.startAdvertisingCount, advertised)
        XCTAssertFalse(adapter.stopAdvertisingCalled)
    }

    func testControlWriteReachesTheAppWithoutAMatchingSubscriberId() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        var received: [(BLETransportChannel, Data)] = []
        transport.onFrameReceived = { received.append(($0, $1)) }
        transport.setForeground(true)
        adapter.emitServicePublished(PhoneRemoteGATT.serviceUUID)

        adapter.emitWrite(
            BLEPeripheralWrite(
                characteristic: PhoneRemoteGATT.macToPhoneControlUUID,
                data: Data([7, 8]),
                subscriberID: "unknown-central"
            )
        )
        XCTAssertEqual(received.map(\.0), [.control])
        XCTAssertEqual(received.map(\.1), [Data([7, 8])])
    }

    func testAdvertisementDictionaryUsesCBUUIDNotFoundationUUID() {
        let data = CoreBluetoothPeripheralManagerAdapter.advertisementData(
            localName: "Phone Remote",
            serviceUUID: PhoneRemoteGATT.serviceUUID
        )
        let uuids = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        XCTAssertEqual(uuids, [CBUUID(nsuuid: PhoneRemoteGATT.serviceUUID)])
        XCTAssertNil(data[CBAdvertisementDataServiceUUIDsKey] as? [UUID])
    }
}

private final class FakePeripheralAdapter: IPhonePeripheralManagerAdapter {
    struct Published {
        let uuid: UUID
        let characteristics: [BLECharacteristicDefinition]
    }

    var state: BLEPeripheralManagerState
    var maximumUpdateValueLength: Int = BLEFramingLimits.minimumValueLength
    var onStateChange: ((BLEPeripheralManagerState) -> Void)?
    var onServicePublished: ((UUID, Error?) -> Void)?
    var onSubscribe: ((String, UUID) -> Void)?
    var onUnsubscribe: ((String, UUID) -> Void)?
    var onWrite: ((BLEPeripheralWrite) -> Void)?
    var onReadyToUpdateSubscribers: (() -> Void)?
    var onAdvertisingStarted: ((Error?) -> Void)?
    var published: [Published] = []
    var advertisedService: UUID?
    var startAdvertisingCount = 0
    var stopAdvertisingCalled = false
    var updateResult: Bool

    init(state: BLEPeripheralManagerState, updateResult: Bool = true) {
        self.state = state
        self.updateResult = updateResult
    }

    func publish(serviceUUID: UUID, characteristics: [BLECharacteristicDefinition]) {
        published.append(Published(uuid: serviceUUID, characteristics: characteristics))
    }

    func startAdvertising(localName: String, serviceUUID: UUID) {
        startAdvertisingCount += 1
        advertisedService = serviceUUID
    }

    func stopAdvertising() {
        stopAdvertisingCalled = true
        advertisedService = nil
    }

    func removeAllServices() {}

    @discardableResult
    func updateValue(_ data: Data, characteristicUUID: UUID) -> Bool {
        updateResult
    }

    func emitServicePublished(_ uuid: UUID) { onServicePublished?(uuid, nil) }
    func emitSubscribe(_ subscriber: String, characteristic: UUID) { onSubscribe?(subscriber, characteristic) }
    func emitWrite(_ write: BLEPeripheralWrite) { onWrite?(write) }
    func emitAdvertisingStarted(error: Error?) { onAdvertisingStarted?(error) }
}
