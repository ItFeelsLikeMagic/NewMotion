import SwiftUI

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

#if os(iOS)
import AVFoundation
import UIKit

private extension BLEPeripheralLifecycleState {
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .waitingForBluetooth: return "Waiting for Bluetooth"
        case .publishing: return "Publishing service"
        case .advertising: return "Advertising"
        case .connected: return "Connected"
        case .ready: return "Ready"
        case .stopped: return "Stopped"
        }
    }
}

/// A deliberately small view model for the prototype UI.  It owns the local
/// push-to-talk and motion sessions, but it does not invent a second transport
/// path: feature adapters continue to emit the shared protocol payloads used
/// by the BLE coordinator.
@MainActor
final class PhoneRemoteFeatureModel: ObservableObject {
    private static let trustedDeviceService = "com.example.phoneremote.ios.trusted-devices"

    @Published var latestAction = "Not paired"
    @Published var isPaired = false
    @Published var microphoneStatus = "Microphone permission not requested"
    @Published var airMouseStatus = "Air mouse idle"
    @Published var airMouseSensitivity = UserDefaults.standard.object(forKey: "airMouseSensitivity") as? Double ?? 2_400
    @Published var trackpadSensitivityX = UserDefaults.standard.object(forKey: "trackpadSensitivityX") as? Double ?? 1.0
    @Published var trackpadSensitivityY = UserDefaults.standard.object(forKey: "trackpadSensitivityY") as? Double ?? 1.0
    @Published var pairingState: IPhonePairingScannerState = .idle
    @Published var bluetoothState: BLEPeripheralLifecycleState = .idle
    @Published var trustedMacName: String?

    private let audioController: LocalPushToTalkAudioController
    private let motionSink: FeatureMotionSink
    private let motionSession: MotionPointerSession
    private let peripheral: IPhoneBLEPeripheralTransport
    private let lifecycle: PhoneLifecycleCoordinator
    let pairingCapture: AVFoundationQRCodeCaptureAdapter
    private let pairingScanner: IPhonePairingScanner
    private let pairingCoordinator: IPhonePairingCoordinator?
    private var pairingClient: PairingHandshakeClient?
    private var pairingToken: PairingToken?
    private var authenticatedSession: PairingSession? {
        didSet { voiceUplink.setSession(authenticatedSession, maximumValueLength: peripheral.maximumUpdateValueLength) }
    }
    private var inboundReassembler: BLEReassembler?
    private var controlReassembler: BLEReassembler?
    private var nextHandshakeMessageID: UInt32 = 1
    private var nextApplicationSequence: UInt64 = 1
    private var handshakeHelloSent = false
    private let pairingConfirmFlag = PairingConfirmFlag()
    private var pairingConfirmed: Bool {
        get { pairingConfirmFlag.value }
        set { pairingConfirmFlag.value = newValue }
    }
    private var trustedPeer: TrustedDeviceSummary?
    private var reconnectFailures = 0
    private let voiceUplink: VoiceUplink
    private var voiceMessagesSent = 0
    private var voiceMessagesDropped = 0
    private var pushToTalkHeld = false
    private var audioSessionObservers: [NSObjectProtocol] = []

    init() {
        let audioController = LocalPushToTalkAudioController(microphone: AVAudioMicrophoneInput())
        self.audioController = audioController
        voiceUplink = VoiceUplink(queue: audioController.queue)
        let motionSink = FeatureMotionSink()
        self.motionSink = motionSink
        motionSession = MotionPointerSession(
            provider: CoreMotionDeviceProvider(),
            sink: motionSink
        )
        let peripheral = IPhoneBLEPeripheralTransport(
            adapter: CoreBluetoothPeripheralManagerAdapter()
        )
        self.peripheral = peripheral
        let confirmFlag = pairingConfirmFlag
        self.lifecycle = PhoneLifecycleCoordinator(
            motion: motionSession,
            audio: audioController,
            disconnectTransport: { peripheral.setForeground(false) },
            attemptReconnect: {
                guard confirmFlag.value else { return }
                peripheral.setForeground(true)
            }
        )
        let capture = AVFoundationQRCodeCaptureAdapter()
        pairingCapture = capture
        pairingScanner = IPhonePairingScanner(
            permission: AVFoundationCameraPermissionAdapter(),
            capture: capture
        )
        pairingCoordinator = try? IPhonePairingCoordinator(
            store: KeychainTrustedDeviceStore(service: Self.trustedDeviceService)
        )
        let reassembledLimit = BLEFramingLimits.maximumEnvelopeBytes + BLEFramingLimits.headerBytes
        inboundReassembler = try? BLEReassembler(maximumValueLength: reassembledLimit)
        controlReassembler = try? BLEReassembler(maximumValueLength: reassembledLimit)
        _ = lifecycle.handle(.startup)

        peripheral.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.handlePeripheralState(state) }
        }
        peripheral.onFrameReceived = { [weak self] channel, data in
            Task { @MainActor [weak self] in self?.handleIncomingFrame(channel: channel, data: data) }
        }

        pairingScanner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.pairingState = state
            }
        }
        pairingScanner.onConfirmationRequired = { [weak self] name, _ in
            Task { @MainActor in
                self?.latestAction = "Confirm pairing with \(name)"
            }
        }
        if let pairingCoordinator {
            pairingCoordinator.onConfirmedPairing = { [weak self] token, _, client in
                Task { @MainActor [weak self] in
                    self?.beginPairingHandshake(token: token, client: client)
                }
            }
            pairingCoordinator.attach(scanner: pairingScanner)
        } else {
            pairingScanner.onConfirmed = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.latestAction = "Pairing storage is unavailable"
                }
            }
        }
        pairingScanner.onRejected = { [weak self] _ in
            Task { @MainActor in
                self?.latestAction = "Pairing offer rejected"
            }
        }
        trustedMacName = pairingCoordinator?.trustedDevices.first?.displayName
        IPhoneDebugLog.emit("trust", ["count": "\(pairingCoordinator?.trustedDevices.count ?? 0)"])
        beginTrustedReconnect()
        motionSink.onDelta = { [weak self] delta in
            // Already on the main queue from FeatureMotionSink. A second
            // Task hop queued every sample and the cursor lagged more the
            // longer the clutch was held.
            MainActor.assumeIsolated {
                self?.handleMotionDelta(delta)
            }
        }
        let uplink = voiceUplink
        audioController.onUtteranceStart = { uplink.beginStream() }
        audioController.onChunk = { uplink.send(samples: $0) }
        audioController.onUtteranceEnd = { uplink.endStream() }
        uplink.deliver = { [weak self] fragments, flags in
            MainActor.assumeIsolated { self?.deliverVoiceFragments(fragments, flags: flags) }
        }
        let center = NotificationCenter.default
        audioSessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if type == AVAudioSession.InterruptionType.began.rawValue { audioController.interruptionBegan() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { audioController.routeChanged() }
            }
        ]
        motionSession.updateFilter(MotionFilterConfiguration(sensitivity: airMouseSensitivity))
        IPhoneDebugLog.emit("app_init", [
            "auth": "\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
            "screenCaptured": UIScreen.main.isCaptured ? "yes" : "no"
        ])
    }

    var isPairingVisible: Bool {
        switch pairingState {
        case .scanning, .requestingCamera, .awaitingConfirmation:
            return true
        case .idle, .paired, .cancelled, .rejected, .failed:
            return false
        }
    }

    func startPairing() {
        latestAction = "Opening camera…"
        audioController.cancel()
        IPhoneDebugLog.emit("tap_scan", [
            "auth": "\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
            "ble": bluetoothState.label
        ])
        pairingClient = nil
        pairingToken = nil
        handshakeHelloSent = false
        pairingConfirmed = false
        authenticatedSession = nil
        isPaired = false
        pairingState = pairingScanner.beginQRPairingScan { [weak self] in
            guard let self else { return }
            IPhoneDebugLog.emit("camera_live", ["ble": self.bluetoothState.label])
        }
        IPhoneDebugLog.emit("after_scan_start", [
            "pairing": "\(pairingState)",
            "visible": isPairingVisible ? "yes" : "no"
        ])
        if pairingState == .rejected {
            latestAction = "Camera access is off"
        } else if pairingState == .failed {
            latestAction = "Camera could not start"
        }
    }

    func confirmPairing() {
        IPhoneDebugLog.emit("tap_confirm", ["pairing": "\(pairingState)"])
        pairingScanner.confirm()
        pairingState = pairingScanner.state
        IPhoneDebugLog.emit("after_confirm", ["pairing": "\(pairingState)"])
    }

    func cancelPairing() {
        pairingScanner.cancel()
        pairingState = pairingScanner.state
        latestAction = "Pairing cancelled"
        resumeReconnectIfNeeded()
    }

    private func resumeReconnectIfNeeded() {
        guard authenticatedSession == nil else { return }
        if pairingCoordinator?.trustedDevices.isEmpty == false {
            beginTrustedReconnect()
        }
    }

    func pulseAdvertisingIfNeeded() {
        if isPairingVisible {
            var fields = pairingCapture.diagnostics()
            fields["pairing"] = "\(pairingState)"
            fields["screenCaptured"] = UIScreen.main.isCaptured ? "yes" : "no"
            IPhoneDebugLog.emit("camera_tick", fields)
        }
        guard authenticatedSession == nil else { return }
        guard pairingConfirmed else { return }
        peripheral.pulseAdvertising()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            _ = lifecycle.handle(.foreground)
            motionSession.setAppActive(true)
            reconnectFailures = 0
            if isPairingVisible {
                // QR scan owns the radio. A saved-Mac reconnect hello would
                // race the new one-time handshake.
                break
            } else if authenticatedSession == nil, pairingCoordinator?.trustedDevices.isEmpty == false {
                beginTrustedReconnect()
            } else {
                peripheral.setForeground(pairingConfirmed)
            }
        case .inactive:
            // Inactive is not background. Stopping BLE here drops advertising
            // while the user still sees the app, so the Mac never reconnects.
            break
        case .background:
            _ = lifecycle.handle(.background)
            motionSession.setAppActive(false)
        @unknown default:
            _ = lifecycle.handle(.background)
            motionSession.setAppActive(false)
        }
    }

    func requestMicrophonePermission() {
        microphoneStatus = "Requesting microphone permission…"
        audioController.requestPermission { [weak self] granted in
            Task { @MainActor in
                self?.microphoneStatus = granted ? "Microphone permission granted" : "Microphone permission denied"
            }
        }
    }

    func pushToTalkPressed() {
        pushToTalkHeld = true
        startHeldPushToTalk()
    }

    func pushToTalkReleased() {
        pushToTalkHeld = false
        audioController.pushToTalkReleased()
        latestAction = "Push to talk released"
    }

    private func startHeldPushToTalk() {
        guard pushToTalkHeld else { return }
        voiceMessagesSent = 0
        voiceMessagesDropped = 0
        audioController.pushToTalkPressed { [weak self] result in
            Task { @MainActor [weak self] in self?.handlePushToTalkStart(result) }
        }
    }

    private func handlePushToTalkStart(_ result: AudioCaptureStartResult) {
        let resultName: String
        switch result {
        case .started:
            resultName = "started"
            latestAction = "Push to talk active"
        case .permissionDenied:
            resultName = "permissionDenied"
            microphoneStatus = "Allow microphone access, then try again"
            audioController.requestPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.microphoneStatus = granted ? "Microphone permission granted" : "Microphone permission denied"
                    if granted { self.startHeldPushToTalk() }
                }
            }
        case .notForeground:
            resultName = "notForeground"
            latestAction = "Push to talk unavailable while backgrounded"
        case .failed:
            resultName = "failed"
            latestAction = "Microphone could not start"
        }
        IPhoneDebugLog.emit("ptt_press", [
            "result": resultName,
            "ble": bluetoothState.label,
            "auth": authenticatedSession != nil ? "yes" : "no"
        ])
    }

    /// A message whose fragments would not all fit is dropped whole; its
    /// sequence number was already advanced on the voice queue.
    private func deliverVoiceFragments(_ fragments: [Data], flags: VoiceStreamFlags) {
        if peripheral.queueCapacity(on: .data) >= fragments.count {
            for fragment in fragments { peripheral.send(fragment, on: .data) }
            voiceMessagesSent += 1
        } else {
            voiceMessagesDropped += 1
        }
        if flags.contains(.end) {
            latestAction = "Voice sent"
            IPhoneDebugLog.emit("ptt_end", [
                "sent": "\(voiceMessagesSent)",
                "dropped": "\(voiceMessagesDropped)",
                "ble": bluetoothState.label
            ])
        }
    }

    func airMouseChanged(_ held: Bool) {
        guard authenticatedSession != nil, peripheral.state == .ready else {
            _ = motionSession.setClutchHeld(false)
            airMouseStatus = held ? "Pair before using air mouse" : "Air mouse idle"
            latestAction = airMouseStatus
            return
        }
        let result = motionSession.setClutchHeld(held)
        if held {
            airMouseStatus = result == .started ? "Air mouse active" : "Air mouse unavailable"
            latestAction = airMouseStatus
        } else {
            airMouseStatus = "Air mouse idle"
            latestAction = "Air mouse released"
        }
    }

    func setAirMouseSensitivity(_ value: Double) {
        airMouseSensitivity = value
        UserDefaults.standard.set(value, forKey: "airMouseSensitivity")
        motionSession.updateFilter(MotionFilterConfiguration(sensitivity: value))
    }

    private func handlePeripheralState(_ state: BLEPeripheralLifecycleState) {
        bluetoothState = state
        IPhoneDebugLog.emit("ble", ["state": state.label])
        switch state {
        case .advertising:
            handshakeHelloSent = false
            _ = lifecycle.handle(.bluetoothPoweredOn)
            if pairingConfirmed, authenticatedSession == nil {
                latestAction = trustedMacName.map { "Reconnecting to \($0)" } ?? "Waiting for Mac to connect"
            }
        case .connected:
            _ = lifecycle.handle(.bluetoothPoweredOn)
            if pairingConfirmed, authenticatedSession == nil {
                latestAction = "Connected; preparing authentication"
            }
        case .ready:
            _ = lifecycle.handle(.bluetoothPoweredOn)
            if authenticatedSession != nil {
                latestAction = "Paired with Mac"
            } else if pairingClient != nil {
                sendHandshakeHelloIfNeeded()
            }
        case .waitingForBluetooth:
            // Waiting is not powered-off. Treating it as off sets isForeground
            // false, so a later powered-on callback never starts advertising.
            if pairingConfirmed { latestAction = "Waiting for Bluetooth" }
        case .publishing, .idle, .stopped:
            break
        }
    }

    private func beginPairingHandshake(token: PairingToken, client: PairingHandshakeClient) {
        pairingConfirmed = true
        pairingToken = token
        pairingClient = client
        authenticatedSession = nil
        handshakeHelloSent = false
        reconnectFailures = 0
        inboundReassembler?.reset()
        IPhoneDebugLog.emit("handshake_begin", ["ble": bluetoothState.label])
        peripheral.setForeground(true)
        latestAction = "Pairing confirmed; waiting for authenticated BLE"
        sendHandshakeHelloIfNeeded()
    }

    private func beginTrustedReconnect() {
        guard authenticatedSession == nil else { return }
        if pairingClient != nil {
            pairingConfirmed = true
            IPhoneDebugLog.emit("reconnect", ["path": "client", "ble": bluetoothState.label])
            peripheral.setForeground(true)
            sendHandshakeHelloIfNeeded()
            return
        }
        guard let pairingCoordinator else {
            IPhoneDebugLog.emit("reconnect_skip", ["reason": "no_store"])
            return
        }
        guard let device = pairingCoordinator.trustedDevices.first else {
            IPhoneDebugLog.emit("reconnect_skip", ["reason": "no_trust"])
            return
        }
        do {
            pairingClient = try pairingCoordinator.makeReconnectClient(for: device.deviceID)
            trustedPeer = device
            trustedMacName = device.displayName
            pairingConfirmed = true
            pairingToken = nil
            handshakeHelloSent = false
            _ = lifecycle.handle(.trustAdded)
            latestAction = "Reconnecting to \(device.displayName)"
            IPhoneDebugLog.emit("reconnect", ["path": "trust", "ble": bluetoothState.label])
            peripheral.setForeground(true)
            sendHandshakeHelloIfNeeded()
        } catch {
            IPhoneDebugLog.emit("reconnect_skip", ["reason": "load_fail"])
            latestAction = "Saved Mac could not be loaded; scan a new QR code"
        }
    }

    private func sendHandshakeHelloIfNeeded() {
        guard !handshakeHelloSent, authenticatedSession == nil,
              let client = pairingClient, peripheral.state == .ready else { return }
        do {
            try sendHandshake(client.hello)
            handshakeHelloSent = true
            IPhoneDebugLog.emit("hello_sent", ["ble": bluetoothState.label])
            latestAction = "Authenticating with Mac…"
            scheduleHandshakeHelloRetry()
        } catch {
            failPairing()
        }
    }

    private func scheduleHandshakeHelloRetry() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard authenticatedSession == nil, pairingClient != nil, pairingConfirmed,
                  peripheral.state == .ready else { return }
            handshakeHelloSent = false
            sendHandshakeHelloIfNeeded()
        }
    }

    func sendPing() {
        guard authenticatedSession != nil, peripheral.state == .ready else {
            latestAction = "Pair first"
            return
        }
        do {
            try sendApplication(.ping(PingPayload()))
            latestAction = "Ping sent"
            IPhoneDebugLog.emit("ping_sent", ["ble": bluetoothState.label])
        } catch {
            latestAction = "Ping failed"
        }
    }

    private func handleIncomingFrame(channel: BLETransportChannel, data: Data) {
        if channel == .data {
            handleApplicationFrame(channel: channel, data: data)
            return
        }
        guard channel == .control, pairingClient != nil, let reassembler = controlReassembler else { return }
        if authenticatedSession != nil { return }
        do {
            switch try reassembler.append(data) {
            case .incomplete, .duplicate:
                return
            case let .complete(payload, kind, _, _):
                guard kind == .control else { throw PairingError.invalidHandshake }
                try acceptServerHello(payload)
            }
        } catch {
            failPairing()
        }
    }

    private func acceptServerHello(_ payload: Data) throws {
        guard let pairingClient, let pairingCoordinator else {
            throw PairingError.invalidHandshake
        }
        let deviceID: UUID
        let displayName: String
        if let pairingToken {
            deviceID = pairingToken.pairingID
            displayName = pairingToken.macDisplayName
        } else if let trustedPeer {
            deviceID = trustedPeer.deviceID
            displayName = trustedPeer.displayName
        } else {
            throw PairingError.invalidHandshake
        }
        let result = try pairingClient.accept(serverHelloData: payload)
        try sendHandshake(result.finish)
        authenticatedSession = result.result.session
        isPaired = true
        reconnectFailures = 0
        nextApplicationSequence = 1
        inboundReassembler?.reset()
        controlReassembler?.reset()
        _ = lifecycle.handle(.trustAdded)
        latestAction = "Paired with \(displayName)"
        IPhoneDebugLog.emit("paired", ["ble": bluetoothState.label])
        do {
            let summary = try pairingCoordinator.rememberPairedMac(
                deviceID: deviceID,
                displayName: displayName,
                peerIdentityPublicKey: result.result.peerIdentityPublicKey
            )
            trustedPeer = summary
            trustedMacName = summary.displayName
            IPhoneDebugLog.emit("trust_save", ["ok": "yes", "count": "\(pairingCoordinator.trustedDevices.count)"])
        } catch {
            IPhoneDebugLog.emit("trust_save", ["ok": "no"])
            latestAction = "Paired, but this phone could not save the Mac"
        }
    }

    private func handleApplicationFrame(channel: BLETransportChannel, data: Data) {
        guard channel == .data, let session = authenticatedSession, let reassembler = inboundReassembler else { return }
        do {
            switch try reassembler.append(data) {
            case .incomplete, .duplicate:
                return
            case let .complete(payload, kind, _, _):
                guard kind == .data else { return }
                let envelope = try session.unwrapApplication(payload)
                if case .pong = envelope.payload {
                    latestAction = "Pong from Mac"
                }
            }
        } catch {
            latestAction = "Link check failed"
        }
    }

    private func sendApplication(_ payload: MessagePayload) throws {
        guard let session = authenticatedSession else { throw PairingError.invalidHandshake }
        let envelope = ProtocolEnvelope(
            sessionID: try SessionID(bytes: Array(session.sessionID)),
            sequence: nextApplicationSequence,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            payload: payload
        )
        nextApplicationSequence = nextApplicationSequence == UInt64.max ? 1 : nextApplicationSequence &+ 1
        let messageID = nextHandshakeMessageID
        nextHandshakeMessageID = messageID == UInt32.max ? 1 : messageID &+ 1
        let frames = try session.wrapApplication(
            envelope,
            messageID: messageID,
            maximumValueLength: peripheral.maximumUpdateValueLength
        )
        let enqueue = envelope.messageType.deliveryClass == .reliable
        for (index, frame) in frames.enumerated() {
            let deliver = enqueue || index > 0
            switch peripheral.send(frame, on: .data, enqueue: deliver) {
            case .sent, .queued:
                continue
            case .notReady, .unsupportedChannel:
                throw PairingError.invalidHandshake
            case .queueFull:
                if deliver { throw PairingError.invalidHandshake }
                return
            }
        }
    }

    private func sendHandshake(_ payload: Data) throws {
        let messageID = nextHandshakeMessageID
        nextHandshakeMessageID = messageID == UInt32.max ? 1 : messageID &+ 1
        let frames = try BLEFragmenter().fragment(
            payload: payload,
            kind: .control,
            reliable: true,
            messageID: messageID,
            maximumValueLength: max(BLEFramingLimits.minimumValueLength, peripheral.maximumUpdateValueLength)
        )
        for frame in frames {
            switch peripheral.send(frame, on: .control) {
            case .sent, .queued:
                continue
            case .notReady, .queueFull, .unsupportedChannel:
                throw PairingError.invalidHandshake
            }
        }
    }

    private func failPairing() {
        let qrInProgress = pairingToken != nil
        let hadTrust = pairingCoordinator?.trustedDevices.isEmpty == false
        IPhoneDebugLog.emit("pairing_fail", [
            "oneTime": qrInProgress ? "yes" : "no",
            "trust": hadTrust ? "yes" : "no",
            "ble": bluetoothState.label
        ])
        pairingClient = nil
        pairingToken = nil
        authenticatedSession = nil
        isPaired = false
        handshakeHelloSent = false
        inboundReassembler?.reset()
        controlReassembler?.reset()
        if qrInProgress {
            pairingConfirmed = false
            peripheral.setForeground(false)
            latestAction = "Pairing failed; scan a new Mac QR code"
            return
        }
        if hadTrust {
            reconnectFailures += 1
            pairingConfirmed = true
            latestAction = "Reconnect failed; retrying"
            let delay = min(8, 1 << min(reconnectFailures, 3))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard authenticatedSession == nil, self.pairingToken == nil else { return }
                beginTrustedReconnect()
            }
            return
        }
        pairingConfirmed = false
        peripheral.setForeground(false)
        latestAction = "Pairing failed; scan a new Mac QR code"
    }

    func handleMotionDelta(_ delta: MotionPointerDelta) {
        guard authenticatedSession != nil, peripheral.state == .ready else { return }
        do {
            try sendApplication(try SharedMotionProtocolAdapter.payload(for: delta, sampleRateHz: 100))
        } catch {
            airMouseStatus = "Air mouse send failed"
        }
    }

    func setTrackpadSensitivity(x: Double? = nil, y: Double? = nil) {
        if let x {
            trackpadSensitivityX = x
            UserDefaults.standard.set(x, forKey: "trackpadSensitivityX")
        }
        if let y {
            trackpadSensitivityY = y
            UserDefaults.standard.set(y, forKey: "trackpadSensitivityY")
        }
    }

    func handleTrackpadOutputs(_ outputs: [TrackpadOutput]) {
        guard authenticatedSession != nil, peripheral.state == .ready else { return }
        for output in outputs {
            switch output {
            case .pointer:
                latestAction = "Trackpad pointer"
            case .scroll:
                latestAction = "Trackpad scroll"
            case .leftClick:
                latestAction = "Left click"
            case .rightClick:
                latestAction = "Right click"
            case .dragBegan:
                latestAction = "Drag began"
            case .dragEnded:
                latestAction = "Drag ended"
            }
            do {
                for payload in try SharedTrackpadProtocolAdapter.payloads(for: output) {
                    try sendApplication(payload)
                }
            } catch {
                latestAction = "Trackpad send failed"
                return
            }
        }
    }
}

/// Lets lifecycle reconnect hooks read pairing state without capturing `self` in `init`.
private final class PairingConfirmFlag {
    var value = false
}

final class FeatureMotionSink: MotionPointerOutputSink, @unchecked Sendable {
    var onDelta: ((MotionPointerDelta) -> Void)?
    var minimumInterval: TimeInterval = 0.04
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var execute: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private let lock = NSLock()
    private var latest: MotionPointerDelta?
    private var scheduled = false
    private var lastFlush: TimeInterval = -.infinity

    func send(_ delta: MotionPointerDelta) {
        lock.lock()
        latest = Self.add(latest, delta)
        let alreadyScheduled = scheduled
        scheduled = true
        lock.unlock()
        guard alreadyScheduled == false else { return }
        scheduleFlush(delay: 0)
    }

    private func scheduleFlush(delay: TimeInterval) {
        execute(delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let pending = latest
        latest = nil
        let interval = minimumInterval
        let elapsed = now() - lastFlush
        lock.unlock()

        if let pending {
            let wait = interval - elapsed
            if wait > 0 {
                lock.lock()
                latest = Self.add(latest, pending)
                lock.unlock()
                scheduleFlush(delay: wait)
                return
            }
            lock.lock()
            lastFlush = now()
            lock.unlock()
            onDelta?(pending)
        }

        lock.lock()
        if latest != nil {
            let wait = max(0, interval - (now() - lastFlush))
            lock.unlock()
            scheduleFlush(delay: wait)
        } else {
            scheduled = false
            lock.unlock()
        }
    }

    private static func add(_ current: MotionPointerDelta?, _ delta: MotionPointerDelta) -> MotionPointerDelta {
        guard let current else { return delta }
        return MotionPointerDelta(x: current.x + delta.x, y: current.y + delta.y)
    }
}

private struct PairingCameraPreview: UIViewRepresentable {
    let capture: AVFoundationQRCodeCaptureAdapter

    func makeUIView(context: Context) -> PairingCameraPreviewView {
        let view = PairingCameraPreviewView(frame: .zero)
        view.attach(capture.previewLayer)
        return view
    }

    func updateUIView(_ view: PairingCameraPreviewView, context: Context) {
        view.attach(capture.previewLayer)
    }
}

private struct TrackpadSurface: UIViewRepresentable {
    let pointerSensitivityX: Double
    let pointerSensitivityY: Double
    let onOutputs: ([TrackpadOutput]) -> Void

    func makeUIView(context: Context) -> TrackpadTouchCaptureView {
        let view = TrackpadTouchCaptureView(frame: .zero)
        view.onOutputs = onOutputs
        view.engine.setSensitivity(pointerX: pointerSensitivityX, pointerY: pointerSensitivityY)
        return view
    }

    func updateUIView(_ uiView: TrackpadTouchCaptureView, context: Context) {
        uiView.onOutputs = onOutputs
        uiView.engine.setSensitivity(pointerX: pointerSensitivityX, pointerY: pointerSensitivityY)
    }
}

struct PhoneRemoteControlView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case trackpad = "Trackpad"
        case airMouse = "Air Mouse"

        var id: Self { self }
    }

    @StateObject private var model = PhoneRemoteFeatureModel()
    @ObservedObject private var debugLog = IPhoneDebugLog.shared
    @State private var mode: Mode = .trackpad
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                    if model.isPairingVisible {
                        PairingCameraPreview(capture: model.pairingCapture)
                            .frame(maxWidth: .infinity)
                            .frame(height: 240)
                            .overlay(alignment: .top) {
                                Text("Hold about 10 in (25 cm) from the code")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.65), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(.top, 8)
                            }

                        if case let .awaitingConfirmation(name, expiry) = model.pairingState {
                            VStack(spacing: 8) {
                                Text("Pair with \(name)?")
                                    .font(.headline)
                                Text("Expires \(expiry.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Confirm") { model.confirmPairing() }
                                        .buttonStyle(.borderedProminent)
                                    Button("Cancel") { model.cancelPairing() }
                                        .buttonStyle(.bordered)
                                }
                            }
                        } else {
                            Button("Cancel scanner") { model.cancelPairing() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button("Scan Mac QR Code") {
                            model.startPairing()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !model.isPairingVisible {
                    Button(model.isPaired ? "Ping Mac" : "Ping Mac (waiting)") {
                        model.sendPing()
                    }
                    .buttonStyle(.bordered)

                    Picker("Control mode", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .trackpad {
                        TrackpadSurface(
                            pointerSensitivityX: model.trackpadSensitivityX,
                            pointerSensitivityY: model.trackpadSensitivityY
                        ) { outputs in
                            model.handleTrackpadOutputs(outputs)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            Text("Swipe, scroll, tap")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                        Slider(
                            value: Binding(
                                get: { model.trackpadSensitivityX },
                                set: { model.setTrackpadSensitivity(x: $0) }
                            ),
                            in: 0.5...6,
                            step: 0.1
                        )
                        Text("Horizontal \(model.trackpadSensitivityX.formatted(.number.precision(.fractionLength(1))))x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.trackpadSensitivityY },
                                set: { model.setTrackpadSensitivity(y: $0) }
                            ),
                            in: 0.5...6,
                            step: 0.1
                        )
                        Text("Vertical \(model.trackpadSensitivityY.formatted(.number.precision(.fractionLength(1))))x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        AirMouseClutchButton { held in
                            model.airMouseChanged(held)
                        }
                        Text(model.airMouseStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.airMouseSensitivity },
                                set: { model.setAirMouseSensitivity($0) }
                            ),
                            in: 500...6_000,
                            step: 100
                        )
                        Text("Pointer speed \(Int(model.airMouseSensitivity))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    }

                    if !model.isPairingVisible {
                    PushToTalkButton(
                        onPress: { model.pushToTalkPressed() },
                        onRelease: { model.pushToTalkReleased() }
                    )

                    Button("Request microphone access") {
                        model.requestMicrophonePermission()
                    }
                    .buttonStyle(.bordered)

                    Text(model.microphoneStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(debugLog.onScreen)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(model.latestAction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Bluetooth: \(model.bluetoothState.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
            }
            .padding()
            .onAppear { model.scenePhaseChanged(.active) }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(phase)
            }
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                model.pulseAdvertisingIfNeeded()
            }
        }
    }
}

@main
struct PhoneRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            PhoneRemoteControlView()
        }
    }
}
#else
@main
struct PhoneRemoteApp: App {
    var body: some Scene {
        WindowGroup { Text("Phone Remote requires iOS") }
    }
}
#endif
