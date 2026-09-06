import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
#endif

public enum PairingCameraAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public protocol PairingCameraPermissionAdapter: AnyObject {
    var authorization: PairingCameraAuthorization { get }
    func requestAccess(completion: @escaping (Bool) -> Void)
}

public protocol PairingQRCodeCaptureAdapter: AnyObject {
    var onCode: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onStarted: (() -> Void)? { get set }
    func start()
    func stop()
}

public enum IPhonePairingScannerState: Equatable {
    case idle
    case requestingCamera
    case scanning
    case paired
    case cancelled
    case rejected
    case failed
}

/// Scanner/coordinator boundary. It validates the complete canonical token
/// before handing it on, and never starts BLE advertising itself. The owner
/// starts advertising only after `onScanned` fires. Scanning is the phone's
/// whole say in pairing; it is the Mac's user who allows the phone.
public final class IPhonePairingScanner {
    public private(set) var state: IPhonePairingScannerState = .idle
    public var onStateChange: ((IPhonePairingScannerState) -> Void)?
    public var onScanned: ((PairingToken) -> Void)?
    public var onRejected: ((PairingError) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let permission: PairingCameraPermissionAdapter
    private let capture: PairingQRCodeCaptureAdapter
    private let clock: PairingClock

    public init(
        permission: PairingCameraPermissionAdapter,
        capture: PairingQRCodeCaptureAdapter,
        clock: PairingClock = SystemPairingClock()
    ) {
        self.permission = permission
        self.capture = capture
        self.clock = clock
        capture.onCode = { [weak self] code in self?.handleCode(code) }
        capture.onFailure = { [weak self] error in self?.handleFailure(error) }
    }

    public func start() {
        IPhoneDebugLog.emit("scanner_start", ["auth": "\(permission.authorization)"])
        switch permission.authorization {
        case .authorized:
            capture.start()
            transition(to: .scanning)
        case .notDetermined:
            transition(to: .requestingCamera)
            permission.requestAccess { [weak self] granted in
                let apply = { [weak self] in
                    guard let self else { return }
                    IPhoneDebugLog.emit("camera_permission", ["granted": granted ? "yes" : "no"])
                    if granted {
                        self.capture.start()
                        self.transition(to: .scanning)
                    } else {
                        self.transition(to: .rejected)
                    }
                }
                if Thread.isMainThread {
                    apply()
                } else {
                    DispatchQueue.main.async(execute: apply)
                }
            }
        case .denied, .restricted:
            transition(to: .rejected)
        }
    }

    /// Start capture. The caller may refresh UI when the camera reports it is
    /// running. Do not tear down BLE here; that blacks the preview and blocks pairing.
    @discardableResult
    public func beginQRPairingScan(onCameraReady: @escaping () -> Void) -> IPhonePairingScannerState {
        capture.onStarted = onCameraReady
        start()
        return state
    }

    public func cancel() {
        capture.stop()
        transition(to: .cancelled)
    }

    /// Explicitly called by the app lifecycle owner when the scanner screen
    /// disappears or the iPhone enters the background.
    public func applicationDidTransitionAway() {
        capture.stop()
        if state == .scanning || state == .requestingCamera {
            transition(to: .cancelled)
        }
    }

    private func handleCode(_ code: String) {
        guard state == .scanning else { return }
        do {
            let token = try PairingToken.decodeText(code)
            guard !token.isExpired(at: clock.now) else {
                capture.stop()
                transition(to: .rejected)
                onRejected?(PairingError.tokenExpired)
                return
            }
            capture.stop()
            transition(to: .paired)
            onScanned?(token)
        } catch let error as PairingError {
            onRejected?(error)
        } catch {
            onRejected?(PairingError.malformedToken)
        }
    }

    private func handleFailure(_ error: Error) {
        capture.stop()
        onFailure?(error)
        transition(to: .failed)
    }

    private func transition(to next: IPhonePairingScannerState) {
        guard state != next else { return }
        state = next
        IPhoneDebugLog.emit("scanner_state", ["state": "\(next)"])
        onStateChange?(next)
    }
}

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import UIKit

public final class AVFoundationCameraPermissionAdapter: PairingCameraPermissionAdapter {
    public init() {}
    public var authorization: PairingCameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
    public func requestAccess(completion: @escaping (Bool) -> Void) {
        let callback = CameraPermissionCompletion(completion)
        AVCaptureDevice.requestAccess(for: .video) { granted in
            callback.call(granted)
        }
    }
}

private final class CameraPermissionCompletion: @unchecked Sendable {
    private let completion: (Bool) -> Void
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func call(_ granted: Bool) { completion(granted) }
}

public final class AVFoundationQRCodeCaptureAdapter: NSObject, PairingQRCodeCaptureAdapter {
    public var onCode: ((String) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var onStarted: (() -> Void)?

    public let captureSession = AVCaptureSession()
    public let previewLayer = AVCaptureVideoPreviewLayer()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let callbackQueue: DispatchQueue
    private let sessionQueue = DispatchQueue(label: "newmotion.camera.session")
    private var configured = false
    private var observers: [NSObjectProtocol] = []

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        super.init()
        // Video-only session. Leave the shared audio session to push-to-talk.
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        captureSession.sessionPreset = .high
        previewLayer.session = captureSession
        previewLayer.videoGravity = .resizeAspectFill
        observeSessionEvents()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The session can report `running=yes` while iOS has taken the feed away.
    private func observeSessionEvents() {
        let center = NotificationCenter.default
        let session = captureSession
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { note in
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            IPhoneDebugLog.emit("camera_interrupted", ["reason": "\(reason)"])
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { _ in
            IPhoneDebugLog.emit("camera_interruption_ended", [:])
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            IPhoneDebugLog.emit("camera_runtime_error", [
                "domain": error?.domain ?? "?",
                "code": "\(error?.code ?? 0)"
            ])
        })
    }

    /// Exposure, ISO, and lens position keep moving while the sensor sees a
    /// real scene. A frozen set with the session running means iOS muted the feed.
    public func diagnostics() -> [String: String] {
        var fields = [
            "running": captureSession.isRunning ? "yes" : "no",
            "interrupted": captureSession.isInterrupted ? "yes" : "no",
            "previewing": previewLayer.isPreviewing ? "yes" : "no"
        ]
        if let device = (captureSession.inputs.first as? AVCaptureDeviceInput)?.device {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            fields["fmt"] = "\(dims.width)x\(dims.height)"
            fields["expMs"] = String(format: "%.2f", device.exposureDuration.seconds * 1000)
            fields["iso"] = String(format: "%.0f", device.iso)
            fields["lens"] = String(format: "%.2f", device.lensPosition)
            fields["zoom"] = String(format: "%.2f", device.videoZoomFactor)
        }
        return fields
    }

    public func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureIfNeeded()
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                var fields = self.diagnostics()
                fields["acat"] = AVAudioSession.sharedInstance().category.rawValue
                IPhoneDebugLog.emit("camera_start", fields)
                self.callbackQueue.async { self.onStarted?() }
            } catch {
                IPhoneDebugLog.emit("camera_start_failed", ["error": String(describing: error)])
                self.callbackQueue.async { self.onFailure?(error) }
            }
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            throw PairingScannerError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input),
              captureSession.canAddOutput(metadataOutput) else {
            captureSession.commitConfiguration()
            throw PairingScannerError.cameraConfigurationFailed
        }
        captureSession.addInput(input)
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: callbackQueue)
        if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
            metadataOutput.metadataObjectTypes = [.qr]
        }
        captureSession.commitConfiguration()
        applyDefaultZoom(to: device)
        configured = true
    }

    /// Pro iPhones cannot focus closer than about 20 cm. A 2x crop lets the QR
    /// code fill the frame from a distance the lens can actually focus at.
    private func applyDefaultZoom(to device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = min(2.0, device.activeFormat.videoMaxZoomFactor)
        device.unlockForConfiguration()
    }
}

/// Hosts the capture adapter's preview layer as a plain sublayer sized to the view.
public final class PairingCameraPreviewView: UIView {
    public private(set) var hostedLayer: AVCaptureVideoPreviewLayer?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.cornerRadius = 16
    }

    required init?(coder: NSCoder) { nil }

    public func attach(_ layer: AVCaptureVideoPreviewLayer) {
        if hostedLayer !== layer {
            hostedLayer?.removeFromSuperlayer()
            hostedLayer = layer
            self.layer.addSublayer(layer)
        }
        applyBounds()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        applyBounds()
    }

    private func applyBounds() {
        guard let layer = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }
}

public enum PairingScannerError: Error, Equatable {
    case cameraUnavailable
    case cameraConfigurationFailed
}

extension AVFoundationQRCodeCaptureAdapter: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = readable.stringValue else { return }
        IPhoneDebugLog.emit("qr_seen", ["bytes": "\(value.utf8.count)"])
        onCode?(value)
    }
}

#endif
