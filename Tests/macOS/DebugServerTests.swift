import Foundation
import XCTest
@testable import NewMotion_macOS

final class DebugServerTests: XCTestCase {
    func testStateResponseIncludesPairingKindAndOmitsSecretFields() throws {
        let snapshot = MacDebugSnapshot(
            status: "Remote: Active",
            paused: false,
            accessibility: "granted",
            link: "Connected",
            linkKind: "connected",
            pairingProgress: "Paired with Phone",
            pairingProgressKind: "paired",
            authenticated: true,
            pairingOffer: "idle",
            hasPairingQR: false,
            pairingError: nil,
            peerName: "Phone",
            pairedDevices: [
                MacDebugPairedDevice(displayName: "Phone", pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ]
        )
        let response = MacDebugHTTP.handle(request: "GET /state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", snapshot: snapshot)
        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"pairingProgressKind\":\"paired\""))
        XCTAssertTrue(json.contains("\"authenticated\":true"))
        XCTAssertTrue(json.contains("\"vocabulary\":\"off\""))
        XCTAssertFalse(json.contains("qrText"))
        XCTAssertFalse(json.contains("prqr1."))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("privateKey"))
        XCTAssertFalse(json.contains("sessionKey"))
        XCTAssertFalse(json.contains("deviceID"))
    }

    func testStateCarriesLatencySummariesAndKeepsKeyPostMs() throws {
        let probes = MacLatencyProbes()
        probes.receiveToInject.record(microseconds: 1_500)
        probes.linkSend.recordRefusal()
        var snapshot = MacDebugSnapshot.empty
        snapshot.keyPostMs = 12.5
        let response = MacDebugHTTP.handle(
            request: "GET /state HTTP/1.1\r\n\r\n",
            snapshot: snapshot,
            latency: { probes.summaries() }
        )
        let json = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"keyPostMs\":12.5"))
        XCTAssertTrue(json.contains("\"name\":\"receiveToInject\""))
        XCTAssertTrue(json.contains("\"medianMs\":1.5"))
        XCTAssertTrue(json.contains("\"name\":\"linkSend\""))
        // A stage that never ran says nothing rather than reading as zero.
        XCTAssertFalse(json.contains("\"name\":\"keyPost\""))
    }

    func testHealthAndUnknownRoutes() {
        let health = MacDebugHTTP.handle(request: "GET /health HTTP/1.1\r\n\r\n", snapshot: .empty)
        XCTAssertEqual(health.status, 200)
        let missing = MacDebugHTTP.handle(request: "GET /secrets HTTP/1.1\r\n\r\n", snapshot: .empty)
        XCTAssertEqual(missing.status, 404)
        let post = MacDebugHTTP.handle(request: "POST /state HTTP/1.1\r\n\r\n", snapshot: .empty)
        XCTAssertEqual(post.status, 405)
    }

    func testLoopbackServerServesCurrentSnapshot() throws {
        let box = MacDebugSnapshotBox(
            MacDebugSnapshot(
                status: "Remote: Active",
                paused: false,
                accessibility: "granted",
                link: "Searching",
                linkKind: "searching",
                pairingProgress: "Paired with Phone",
                pairingProgressKind: "paired",
                authenticated: true,
                pairingOffer: "idle",
                hasPairingQR: false
            )
        )
        let server = MacDebugHTTPServer(box: box, preferredPort: 18775, portFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("newmotion-debug-test.json"))
        defer { server.stop() }
        server.start()

        let deadline = Date().addingTimeInterval(2)
        var port: UInt16?
        while Date() < deadline, port == nil {
            port = server.port
            if port == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        let bound = try XCTUnwrap(port)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(bound)/state"))
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"pairingProgressKind\":\"paired\""))
        XCTAssertTrue(json.contains("\"linkKind\":\"searching\""))
    }

    func testTheCardRoutesCarryACellNameOrNothingAtAll() throws {
        let snapshot = MacDebugSnapshot(
            status: "Remote: Active",
            paused: false,
            accessibility: "granted",
            link: "Connected",
            linkKind: "connected",
            pairingProgress: "Paired with Phone",
            pairingProgressKind: "paired",
            authenticated: true,
            pairingOffer: "idle",
            hasPairingQR: false,
            pairingError: nil,
            peerName: "Phone"
        )
        var asked: [MacDebugCardRequest] = []
        func respond(_ request: String) -> MacDebugHTTP.Response {
            MacDebugHTTP.handle(
                request: "GET \(request) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                snapshot: snapshot,
                card: { asked.append($0); return ["ok": "1"] }
            )
        }
        XCTAssertEqual(respond("/picker?cell=save").status, 200)
        XCTAssertEqual(respond("/picker").status, 200)
        XCTAssertEqual(respond("/arrows?lit=up").status, 200)
        XCTAssertEqual(respond("/arrows").status, 200)
        XCTAssertEqual(respond("/hint").status, 200)
        XCTAssertEqual(asked, [
            .picker(cell: "save"),
            .picker(cell: nil),
            .arrows(lit: "up"),
            .arrows(lit: nil),
            .hint
        ])
    }
}
