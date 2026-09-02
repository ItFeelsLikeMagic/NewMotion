import AVFoundation
import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import PhoneRemote_iOS
@testable import PhoneRemoteShared

final class PairingScannerTests: XCTestCase {
    func testScannerRequiresExplicitConfirmationAndStopsCameraOnAllOutcomes() throws {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        var confirmations = 0
        scanner.onConfirmed = { _ in confirmations += 1 }
        scanner.start()
        XCTAssertEqual(scanner.state, .scanning)
        capture.emit("not-a-pairing-token")
        XCTAssertEqual(scanner.state, .scanning)
        let token = try makeTestToken()
        capture.emit(try token.encodeText())
        guard case let .awaitingConfirmation(name, expiresAt) = scanner.state else {
            return XCTFail("expected confirmation state")
        }
        XCTAssertEqual(name, "Mac")
        // Token timestamps are canonicalized to milliseconds on the wire.
        XCTAssertEqual(expiresAt.timeIntervalSince1970, token.expiresAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(capture.stopCount, 1)
        scanner.confirm()
        scanner.confirm()
        XCTAssertEqual(confirmations, 1)

        let cancelledCapture = FakeQRCodeCapture()
        let cancelled = IPhonePairingScanner(permission: permission, capture: cancelledCapture)
        cancelled.start()
        cancelled.cancel()
        cancelledCapture.emit(try token.encodeText())
        cancelled.confirm()
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelledCapture.stopCount, 1)
    }

    func testScannerRejectsExpiredTokenBeforeConfirmation() throws {
        let clock = MutablePairingClock(Date(timeIntervalSince1970: 500))
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture, clock: clock)
        var rejected: PairingError?
        scanner.onRejected = { rejected = $0 }
        scanner.start()
        let token = try PairingToken(
            macDisplayName: "Mac",
            macEphemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            oneTimeSecret: Data(repeating: 5, count: 32),
            pairingID: UUID(),
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        capture.emit(try token.encodeText())
        XCTAssertEqual(scanner.state, .rejected)
        XCTAssertEqual(rejected, .tokenExpired)
        XCTAssertNil(scanner.pendingToken)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testCoordinatorReconnectsFromPersistedTrustWithoutQR() throws {
        let store = InMemoryTrustedDeviceStore()
        let phone = try IPhonePairingCoordinator(store: store)
        let macIdentity = PairingIdentity()
        let deviceID = UUID()
        _ = try phone.rememberPairedMac(
            deviceID: deviceID,
            displayName: "Mac",
            peerIdentityPublicKey: macIdentity.publicKey
        )

        let relaunched = try IPhonePairingCoordinator(store: store)
        XCTAssertEqual(relaunched.identity.publicKey, phone.identity.publicKey)
        let client = try relaunched.makeReconnectClient(for: deviceID)
        let hello = try PairingClientHello.decode(client.hello)
        XCTAssertEqual(hello.pairingID, deviceID)

        let server = PairingHandshakeServer(
            mode: .trusted(deviceID: deviceID, peerIdentityPublicKey: relaunched.identity.publicKey),
            identity: macIdentity,
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey()
        )
        let serverHello = try server.accept(clientHelloData: client.hello)
        let clientResult = try client.accept(serverHelloData: serverHello.response)
        let serverResult = try server.accept(clientFinishData: clientResult.finish)
        XCTAssertEqual(clientResult.result.session.sessionID, serverResult.session.sessionID)
    }

    func testScannerStopsOnApplicationTransition() {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        scanner.start()
        scanner.applicationDidTransitionAway()
        XCTAssertEqual(scanner.state, .cancelled)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testQRScanDefersAdvertisingStopUntilCameraReportsStarted() {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        capture.deferStarted = true
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        var cameraStarts = 0
        var advertisingStops = 0
        capture.onStart = { cameraStarts += 1 }

        _ = scanner.beginQRPairingScan {
            XCTAssertEqual(cameraStarts, 1)
            advertisingStops += 1
        }

        XCTAssertEqual(cameraStarts, 1)
        XCTAssertEqual(advertisingStops, 0)
        capture.emitStarted()
        XCTAssertEqual(advertisingStops, 1)
    }

    func testQRScanStartsCameraBeforeStoppingAdvertising() {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        var events: [String] = []
        capture.onStart = { events.append("camera") }

        let state = scanner.beginQRPairingScan {
            events.append("camera-ready")
            XCTAssertEqual(capture.startCount, 1)
        }

        XCTAssertEqual(state, .scanning)
        XCTAssertEqual(scanner.state, .scanning)
        XCTAssertEqual(events, ["camera", "camera-ready"])
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 0)
    }

    func testQRScanReportsReadyAfterStartWithoutRequiringACallerStop() {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        capture.deferStarted = true
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        var ready = false
        let state = scanner.beginQRPairingScan { ready = true }
        XCTAssertEqual(state, .scanning)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertFalse(ready)
        capture.emitStarted()
        XCTAssertTrue(ready)
    }

    func testQRScanStartsCameraAgainAfterCancelAndAfterPaired() throws {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)

        XCTAssertEqual(scanner.beginQRPairingScan(onCameraReady: {}), .scanning)
        scanner.cancel()
        XCTAssertEqual(scanner.state, .cancelled)
        XCTAssertEqual(scanner.beginQRPairingScan(onCameraReady: {}), .scanning)
        XCTAssertEqual(capture.startCount, 2)

        let token = try makeTestToken()
        capture.emit(try token.encodeText())
        scanner.confirm()
        XCTAssertEqual(scanner.state, .paired)
        XCTAssertEqual(scanner.beginQRPairingScan(onCameraReady: {}), .scanning)
        XCTAssertEqual(capture.startCount, 3)
    }

    func testAuthorizedStartKeepsScanningWhenCaptureIsRestarted() {
        let permission = FakeCameraPermission(authorization: .authorized)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        scanner.start()
        XCTAssertEqual(scanner.state, .scanning)
        capture.start()
        XCTAssertEqual(scanner.state, .scanning)
        XCTAssertEqual(capture.startCount, 2)
    }

    func testNotDeterminedPermissionGrantStartsCameraOnCallingThread() {
        let permission = FakeCameraPermission(authorization: .notDetermined, grant: true)
        let capture = FakeQRCodeCapture()
        let scanner = IPhonePairingScanner(permission: permission, capture: capture)
        scanner.start()
        XCTAssertEqual(scanner.state, .scanning)
        XCTAssertEqual(capture.startCount, 1)
    }

    @MainActor
    func testPreviewViewBackingLayerFillsBounds() {
        let view = PairingCameraPreviewView(frame: .zero)
        let layer = AVCaptureVideoPreviewLayer()
        view.attach(layer)
        XCTAssertTrue(view.hostedLayer === layer)

        view.bounds = CGRect(x: 0, y: 0, width: 180, height: 220)
        view.layoutIfNeeded()
        XCTAssertEqual(layer.frame.size, CGSize(width: 180, height: 220))
        XCTAssertEqual(view.layer.bounds.size, CGSize(width: 180, height: 220))
    }

    func testCaptureSessionDoesNotTakeOverApplicationAudio() {
        let capture = AVFoundationQRCodeCaptureAdapter()
        XCTAssertFalse(capture.captureSession.automaticallyConfiguresApplicationAudioSession)
        XCTAssertTrue(capture.previewLayer.session === capture.captureSession)
    }

    @MainActor
    func testDebugLogOmitsSecretFields() async throws {
        IPhoneDebugLog.emit("unit_test", ["secret": "nope", "running": "yes"])
        try await Task.sleep(for: .milliseconds(80))
        let text = IPhoneDebugLog.shared.onScreen
        XCTAssertTrue(text.contains("running=yes"))
        XCTAssertFalse(text.contains("nope"))
        XCTAssertFalse(text.contains("secret="))
    }

    @MainActor
    func testDebugLogRecordsPTTCountsWithoutAudioBytes() async throws {
        IPhoneDebugLog.emit("ptt_send", ["flags": "start", "bytes": "32", "payload": "secret-audio"])
        try await Task.sleep(for: .milliseconds(80))
        let text = IPhoneDebugLog.shared.onScreen
        XCTAssertTrue(text.contains("e=ptt_send"))
        XCTAssertTrue(text.contains("flags=start"))
        XCTAssertTrue(text.contains("bytes=32"))
        XCTAssertFalse(text.contains("secret-audio"))
        XCTAssertFalse(text.contains("payload="))
    }


    private func makeTestToken() throws -> PairingToken {
        try PairingToken(
            macDisplayName: "Mac",
            macEphemeralPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            oneTimeSecret: Data(repeating: 4, count: 32),
            pairingID: UUID(),
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(119)
        )
    }
}

private final class MutablePairingClock: PairingClock {
    var nowValue: Date
    init(_ now: Date) { nowValue = now }
    var now: Date { nowValue }
}

private final class FakeCameraPermission: PairingCameraPermissionAdapter {
    var authorization: PairingCameraAuthorization
    var grant: Bool
    init(authorization: PairingCameraAuthorization, grant: Bool? = nil) {
        self.authorization = authorization
        self.grant = grant ?? (authorization == .authorized)
    }
    func requestAccess(completion: @escaping (Bool) -> Void) {
        if grant { authorization = .authorized }
        completion(grant)
    }
}

private final class FakeQRCodeCapture: PairingQRCodeCaptureAdapter {
    var onCode: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStart: (() -> Void)?
    var onStarted: (() -> Void)?
    var deferStarted = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() {
        startCount += 1
        onStart?()
        if !deferStarted { onStarted?() }
    }
    func stop() { stopCount += 1 }
    func emit(_ value: String) { onCode?(value) }
    func emitStarted() { onStarted?() }
}
