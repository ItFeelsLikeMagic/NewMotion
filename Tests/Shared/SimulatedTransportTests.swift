import XCTest
@testable import NewMotionShared

final class SimulatedTransportTests: XCTestCase {
    func testConnectDelayOrderedDeliveryAndDisconnect() {
        let transport = SimulatedTransport(configuration: .init(delayTicks: 2, maximumQueueDepth: 8))
        var received: [[UInt8]] = []
        var states: [TransportConnectionState] = []
        transport.endpointB.onReceive = { received.append($0) }
        transport.endpointA.onStateChange = { states.append($0) }

        XCTAssertFalse(transport.endpointA.isConnected)
        transport.connect()
        XCTAssertEqual(states, [.connected])
        XCTAssertEqual(transport.endpointA.send([1]), .queued)
        XCTAssertEqual(received, [])
        transport.advance(by: 1)
        XCTAssertEqual(received, [])
        transport.advance(by: 1)
        XCTAssertEqual(received, [[1]])
        transport.endpointA.disconnect()
        XCTAssertEqual(states.last, .disconnected)
        XCTAssertEqual(transport.endpointA.send([2]), .disconnected)
    }

    func testLossAndDuplicationAreDeterministic() {
        let loss = SimulatedTransport(configuration: .init(lossRatePermille: 1_000, seed: 42))
        loss.connect()
        XCTAssertEqual(loss.endpointA.send([1, 2]), .dropped)
        loss.drain()
        XCTAssertFalse(loss.traceEvents.contains { $0.kind == .delivered })

        let duplicate = SimulatedTransport(configuration: .init(duplicationRatePermille: 1_000, seed: 42))
        var received: [[UInt8]] = []
        duplicate.endpointB.onReceive = { received.append($0) }
        duplicate.connect()
        XCTAssertEqual(duplicate.endpointA.send([3]), .queued)
        duplicate.drain()
        XCTAssertEqual(received, [[3], [3]])
        XCTAssertEqual(duplicate.traceEvents.filter { $0.kind == .duplicated }.count, 1)
    }

    func testSameSeedProducesSameTraceIncludingReordering() {
        func run() -> [SimulatedTransport.TraceEvent] {
            let transport = SimulatedTransport(configuration: .init(
                delayTicks: 1,
                duplicationRatePermille: 500,
                reorderingWindow: 3,
                maximumQueueDepth: 32,
                seed: 987
            ))
            transport.connect()
            for value in 0..<8 { _ = transport.endpointA.send([UInt8(value)]) }
            transport.advance(by: 1)
            transport.drain()
            return transport.traceEvents
        }
        XCTAssertEqual(run(), run())
    }

    func testReorderingWindowCanDeliverLaterPacketFirst() {
        let transport = SimulatedTransport(configuration: .init(reorderingWindow: 2, seed: 2))
        var received: [[UInt8]] = []
        transport.endpointB.onReceive = { received.append($0) }
        transport.connect()
        _ = transport.endpointA.send([1])
        _ = transport.endpointA.send([2])
        transport.drain()
        XCTAssertEqual(received.count, 2)
        XCTAssertNotEqual(received, [[1], [2]])
    }

    func testBoundedQueueOverflowIsVisible() {
        let transport = SimulatedTransport(configuration: .init(delayTicks: 10, maximumQueueDepth: 1, seed: 1))
        transport.connect()
        XCTAssertEqual(transport.endpointA.send([1]), .queued)
        XCTAssertEqual(transport.endpointA.send([2]), .overflow)
        XCTAssertEqual(transport.queuedPacketCount, 1)
        XCTAssertTrue(transport.traceEvents.contains { $0.kind == .overflow })
    }
}
