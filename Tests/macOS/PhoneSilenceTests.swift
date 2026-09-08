import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// The Mac noticing on its own that the phone on the other end has gone.
@MainActor
final class PhoneSilenceTests: XCTestCase {
    func testAQuietPhoneIsDroppedAndTheMacScansAgain() {
        let clock = MutableDate(Date(timeIntervalSince1970: 1_000))
        let adapter = FakeCentralAdapter()
        let model = MacRemoteAppModel(centralAdapter: adapter, now: { clock.value })
        let peripheral = connect(adapter)
        XCTAssertEqual(model.linkState, .connected)

        clock.value += 8
        model.pollPhone()
        XCTAssertEqual(model.linkState, .connected, "eight seconds is a slow phone, not a dead one")

        clock.value += 5
        model.pollPhone()
        XCTAssertEqual(model.linkState, .searching)
        XCTAssertEqual(adapter.cancelledConnections, [peripheral.identifier])
    }

    func testAnythingThePhoneSaysResetsTheClock() throws {
        let clock = MutableDate(Date(timeIntervalSince1970: 1_000))
        let adapter = FakeCentralAdapter()
        let model = MacRemoteAppModel(centralAdapter: adapter, now: { clock.value })
        let peripheral = connect(adapter)

        clock.value += 8
        // Not a hello, so the handshake refuses it; the phone is still there.
        for frame in try BLEFragmenter().fragment(
            payload: Data([1, 2, 3]),
            kind: .control,
            reliable: true,
            messageID: 1,
            maximumValueLength: BLEFramingLimits.minimumValueLength
        ) {
            adapter.emitValue(peripheral.identifier, characteristicUUID: NewMotionGATT.phoneToMacControlUUID, data: frame)
        }

        clock.value += 9
        model.pollPhone()
        XCTAssertEqual(model.linkState, .connected)

        clock.value += 4
        model.pollPhone()
        XCTAssertEqual(model.linkState, .searching)
    }

    /// The same GATT dance the link tests use; no beacon is needed because a
    /// scanning link takes whatever discovery hands it.
    private func connect(_ adapter: FakeCentralAdapter) -> BLEDiscoveredPeripheral {
        let peripheral = BLEDiscoveredPeripheral(identifier: UUID(), name: "Phone")
        adapter.emitDiscover(peripheral)
        adapter.emitConnected(peripheral.identifier)
        adapter.emitServices(peripheral.identifier, services: [NewMotionGATT.serviceUUID])
        adapter.emitCharacteristics(peripheral.identifier, serviceUUID: NewMotionGATT.serviceUUID, characteristics: NewMotionGATT.allCharacteristicUUIDs)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: NewMotionGATT.phoneToMacDataUUID)
        adapter.emitNotification(peripheral.identifier, characteristicUUID: NewMotionGATT.phoneToMacControlUUID)
        return peripheral
    }
}

private final class MutableDate {
    var value: Date
    init(_ value: Date) { self.value = value }
}
