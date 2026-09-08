import CoreBluetooth
import Foundation
import XCTest
@testable import NewMotion_iOS
@testable import NewMotionShared

final class BluetoothPeripheralTests: XCTestCase {
    private static let beacon = UUID()

    func testPeripheralWaitsForForegroundAndPoweredOnBeforeAdvertising() {
        let adapter = FakePeripheralAdapter(state: .poweredOff)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)

        transport.setForeground(true)
        XCTAssertEqual(transport.state, .waitingForBluetooth)
        XCTAssertTrue(adapter.published.isEmpty)
        XCTAssertTrue(adapter.advertisedService == nil)

        adapter.state = .poweredOn
        adapter.onStateChange?(.poweredOn)
        XCTAssertEqual(transport.state, .publishing)
        XCTAssertEqual(adapter.published.map(\.uuid), [NewMotionGATT.serviceUUID])
        XCTAssertNil(adapter.advertisedService)

        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.advertisedService, Self.beacon)
    }

    func testPeripheralRequiresBothDataSubscriptionsForReady() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)

        let subscriber = "mac-test"
        adapter.emitSubscribe(subscriber, characteristic: NewMotionGATT.phoneToMacDataUUID)
        XCTAssertEqual(transport.state, .connected)
        adapter.emitSubscribe(subscriber, characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        XCTAssertEqual(transport.subscriberIDs, Set([subscriber]))

        transport.setForeground(false)
        XCTAssertEqual(transport.state, .stopped)
        XCTAssertTrue(adapter.stopAdvertisingCalled)
    }

    func testBackgroundTakesTheServiceDownAndForegroundRepublishesIt() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        var states: [BLEPeripheralLifecycleState] = []
        transport.onStateChange = { states.append($0) }
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        states.removeAll()

        transport.setForeground(false)
        XCTAssertEqual(transport.state, .stopped)
        XCTAssertTrue(adapter.stopAdvertisingCalled)
        XCTAssertTrue(adapter.removeAllServicesCalled)
        XCTAssertTrue(transport.subscriberIDs.isEmpty)

        // A subscriber from before the trip is not one the phone can still
        // count on: the Mac drops a link whose service vanished.
        adapter.emitUnsubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        XCTAssertEqual(transport.state, .stopped)

        transport.setForeground(true)
        XCTAssertEqual(transport.state, .publishing)
        XCTAssertEqual(adapter.published.count, 2)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 2)
        adapter.emitSubscribe("mac-again", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-again", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        // The app relies on the trip through `.advertising` to handshake again.
        XCTAssertEqual(states, [.stopped, .publishing, .advertising, .connected, .ready])
    }

    func testLosingTheLastSubscriberRelightsTheBeacon() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)

        // The Mac is one subscriber; dropping either channel ends the link.
        adapter.emitUnsubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 2)

        adapter.emitUnsubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(adapter.startAdvertisingCount, 2)
    }

    func testAFreshCentralReplacesAStaleSubscriberAndForcesAHandshake() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        var states: [BLEPeripheralLifecycleState] = []
        transport.onStateChange = { states.append($0) }
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-old", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-old", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        states.removeAll()

        adapter.emitSubscribe("mac-new", characteristic: NewMotionGATT.phoneToMacDataUUID)
        XCTAssertEqual(states, [.advertising, .connected])
        XCTAssertEqual(transport.subscriberIDs, Set(["mac-new"]))
        adapter.emitSubscribe("mac-new", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
    }

    func testPeripheralQueueIsBoundedAndDisconnectClearsFrames() {
        let adapter = FakePeripheralAdapter(state: .poweredOn, updateResult: false)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter, queueLimit: 2)
        transport.setBeacon(Self.beacon)
        var queueFull: [BLETransportChannel] = []
        transport.onQueueFull = { queueFull.append($0) }
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
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
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)

        XCTAssertEqual(transport.send(Data([1]), on: .data, enqueue: false), .queueFull)
        XCTAssertEqual(transport.queuedFrameCount, 0)
        XCTAssertEqual(transport.send(Data([2]), on: .data, enqueue: true), .queued)
        XCTAssertEqual(transport.queuedFrameCount, 1)
    }

    func testQueueCapacityCountsFreeSlotsOnlyWhenReady() {
        let adapter = FakePeripheralAdapter(state: .poweredOn, updateResult: false)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter, queueLimit: 2)
        transport.setBeacon(Self.beacon)
        XCTAssertEqual(transport.queueCapacity(on: .data), 0)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.queueCapacity(on: .data), 2)
        XCTAssertEqual(transport.send(Data([1]), on: .data), .queued)
        XCTAssertEqual(transport.queueCapacity(on: .data), 1)
        XCTAssertEqual(transport.queueCapacity(on: .control), 2)
    }

    /// A `latestWins` message is never queued and never repaired, so half of
    /// one on the wire is words the Mac can never put back together and a
    /// caller who was told they arrived.
    func testAMultiFragmentLatestWinsMessageIsRefusedWhole() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        // Four payload bytes a fragment, two free slots: twelve bytes is one
        // fragment more than fits.
        let transport = readyTransport(adapter: adapter, queueLimit: 2)
        let link = BLEMessageLink(peripheral: transport)

        let result = link.send(Data(repeating: 7, count: 12), on: .data, delivery: .latestWins)

        XCTAssertEqual(result, .busy)
        XCTAssertTrue(adapter.updates.isEmpty)
    }

    func testAMultiFragmentLatestWinsMessageGoesOutWhenItFits() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = readyTransport(adapter: adapter, queueLimit: 4)
        let link = BLEMessageLink(peripheral: transport)

        let result = link.send(Data(repeating: 7, count: 12), on: .data, delivery: .latestWins)

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(adapter.updates.count, 3)
        XCTAssertEqual(transport.queuedFrameCount, 0, "a preview never queues")
    }

    private func readyTransport(
        adapter: FakePeripheralAdapter,
        queueLimit: Int
    ) -> IPhoneBLEPeripheralTransport {
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter, queueLimit: queueLimit)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        return transport
    }

    func testAdvertisingStartErrorDoesNotTearDownALiveBeacon() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        var errors = 0
        transport.onTransportError = { _ in errors += 1 }
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)

        adapter.emitAdvertisingStarted(error: BLEFramingError.invalidFlags)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)
    }

    func testPulseDoesNotRestartALiveAdvertisement() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)

        transport.pulseAdvertising()
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)

        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)
        transport.pulseAdvertising()
        XCTAssertEqual(adapter.startAdvertisingCount, 1)
        XCTAssertEqual(transport.state, .ready)
    }

    func testPulseRestartsAdvertisingAfterAStop() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        transport.stop()
        XCTAssertEqual(transport.state, .stopped)

        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 2)
    }

    func testPulseDoesNotRepublishWhileServiceIsPublishing() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
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
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
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
        transport.setBeacon(Self.beacon)
        var received: [(BLETransportChannel, Data)] = []
        transport.onFrameReceived = { received.append(($0, $1)) }
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)

        adapter.emitWrite(
            BLEPeripheralWrite(
                characteristic: NewMotionGATT.macToPhoneControlUUID,
                data: Data([7, 8]),
                subscriberID: "unknown-central"
            )
        )
        XCTAssertEqual(received.map(\.0), [.control])
        XCTAssertEqual(received.map(\.1), [Data([7, 8])])
    }

    func testWithoutABeaconTheServiceIsPublishedButNeverAdvertised() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setForeground(true)
        XCTAssertEqual(transport.state, .publishing)
        XCTAssertEqual(adapter.published.map(\.uuid), [NewMotionGATT.serviceUUID])

        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .stopped)
        XCTAssertEqual(adapter.startAdvertisingCount, 0)
        XCTAssertNil(adapter.advertisedService)

        transport.setBeacon(Self.beacon)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)
        XCTAssertEqual(adapter.advertisedService, Self.beacon)
        XCTAssertEqual(adapter.published.count, 1)
    }

    func testChangingTheBeaconWhileAdvertisingRestartsTheAdvertisement() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)

        transport.setBeacon(Self.beacon)
        XCTAssertEqual(adapter.startAdvertisingCount, 1)
        XCTAssertFalse(adapter.stopAdvertisingCalled)

        let other = UUID()
        transport.setBeacon(other)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertTrue(adapter.stopAdvertisingCalled)
        XCTAssertEqual(adapter.startAdvertisingCount, 2)
        XCTAssertEqual(adapter.advertisedService, other)
    }

    /// Pairing with a second Mac while the first is still subscribed. The old
    /// Mac never hangs up, so unless the phone drops the service here it never
    /// advertises the new beacon and the new Mac scans forever.
    func testSettingTheBeaconWhileReadyDropsTheLinkAndReadvertises() {
        let adapter = FakePeripheralAdapter(state: .poweredOn)
        let transport = IPhoneBLEPeripheralTransport(adapter: adapter)
        transport.setBeacon(Self.beacon)
        transport.setForeground(true)
        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitSubscribe("mac-test", characteristic: NewMotionGATT.phoneToMacControlUUID)
        XCTAssertEqual(transport.state, .ready)

        let other = UUID()
        transport.setBeacon(other)
        XCTAssertEqual(transport.beacon, other)
        XCTAssertTrue(adapter.removeAllServicesCalled)
        XCTAssertTrue(transport.subscriberIDs.isEmpty)

        adapter.emitServicePublished(NewMotionGATT.serviceUUID)
        XCTAssertEqual(transport.state, .advertising)
        XCTAssertEqual(adapter.advertisedService, other)
    }

    func testAdvertisementDictionaryUsesCBUUIDNotFoundationUUID() {
        let data = CoreBluetoothPeripheralManagerAdapter.advertisementData(
            localName: "NewMotion",
            serviceUUID: NewMotionGATT.serviceUUID
        )
        let uuids = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        XCTAssertEqual(uuids, [CBUUID(nsuuid: NewMotionGATT.serviceUUID)])
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
    var removeAllServicesCalled = false
    var updateResult: Bool
    /// What actually went out, so a test can tell a whole message from half of
    /// one.
    private(set) var updates: [Data] = []

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

    func removeAllServices() { removeAllServicesCalled = true }

    @discardableResult
    func updateValue(_ data: Data, characteristicUUID: UUID) -> Bool {
        guard updateResult else { return false }
        updates.append(data)
        return true
    }

    func emitServicePublished(_ uuid: UUID) { onServicePublished?(uuid, nil) }
    func emitSubscribe(_ subscriber: String, characteristic: UUID) { onSubscribe?(subscriber, characteristic) }
    func emitUnsubscribe(_ subscriber: String, characteristic: UUID) { onUnsubscribe?(subscriber, characteristic) }
    func emitWrite(_ write: BLEPeripheralWrite) { onWrite?(write) }
    func emitAdvertisingStarted(error: Error?) { onAdvertisingStarted?(error) }
}
