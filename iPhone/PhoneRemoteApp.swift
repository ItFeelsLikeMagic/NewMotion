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
    @Published var airMouseStatus = "Air mouse idle"
    @Published var airMouseSensitivity = UserDefaults.standard.object(forKey: "airMouseSensitivity") as? Double ?? 2_400
    @Published var trackpadSensitivityX = UserDefaults.standard.object(forKey: "trackpadSensitivityX") as? Double ?? 1.0
    @Published var trackpadSensitivityY = UserDefaults.standard.object(forKey: "trackpadSensitivityY") as? Double ?? 1.0
    @Published var pairingState: IPhonePairingScannerState = .idle
    @Published var bluetoothState: BLEPeripheralLifecycleState = .idle
    @Published var trustedMacName: String?

    private let audioController: LocalPushToTalkAudioController
    private(set) lazy var pushToTalk = PushToTalkController(
        audio: audioController,
        activity: { [weak self] in self?.latestAction = $0 },
        logContext: { [weak self] in
            [
                "ble": self?.bluetoothState.label ?? "unknown",
                "auth": self?.authenticatedSession != nil ? "yes" : "no"
            ]
        }
    )
    private let motionSink: DeltaCoalescer<MotionPointerDelta>
    private let trackpadOutputs = TrackpadOutputCoalescer()
    /// Cursor travel the radio has not taken yet, in whole points.
    private var pendingPointerX = 0
    private var pendingPointerY = 0
    private var pendingScrollX = 0
    private var pendingScrollY = 0
    private lazy var keyboardForwarder = KeyboardOutputForwarder { [weak self] output in
        self?.sendKeyboardOutput(output)
    }
    private lazy var keyboard = KeyboardInputController(sink: keyboardForwarder)
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
    private var audioSessionObservers: [NSObjectProtocol] = []

    init() {
        let audioController = LocalPushToTalkAudioController(
            microphone: AVAudioMicrophoneInput(),
            permissionGranted: AVAudioApplication.shared.recordPermission == .granted
        )
        self.audioController = audioController
        voiceUplink = VoiceUplink(queue: audioController.queue)
        let motionSink = DeltaCoalescer<MotionPointerDelta>.motionPointer()
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
        peripheral.onReadyToSend = { [weak self] in
            MainActor.assumeIsolated { self?.flushCursorStream() }
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
        motionSink.onFlush = { [weak self] delta in
            // Already on the main queue from the coalescer. A second Task hop
            // queued every sample and the cursor lagged more the longer the
            // clutch was held.
            MainActor.assumeIsolated {
                self?.handleMotionDelta(delta)
            }
        }
        trackpadOutputs.onOutput = { [weak self] output in
            MainActor.assumeIsolated {
                self?.sendTrackpadOutput(output)
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

    /// A message whose fragments would not all fit is dropped whole; its
    /// sequence number was already advanced on the voice queue.
    private func deliverVoiceFragments(_ fragments: [Data], flags: VoiceStreamFlags) {
        if flags.contains(.start) {
            voiceMessagesSent = 0
            voiceMessagesDropped = 0
        }
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
            if authenticatedSession != nil {
                // The Mac dropped the link (typically its app restarted), and
                // its side of the session went with it; handshake again.
                authenticatedSession = nil
                pairingClient = nil
                inboundReassembler?.reset()
                IPhoneDebugLog.emit("session_lost", ["ble": bluetoothState.label])
                beginTrustedReconnect()
            }
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
        guard isControllable else { return }
        trackpadOutputs.handle(outputs)
    }

    /// Characters are forwarded as they are typed and never stored or logged.
    func typeText(_ text: String) {
        guard isControllable else {
            latestAction = "Pair before typing"
            return
        }
        keyboard.type(text)
    }

    /// The switcher holds Command open on the Mac between begin and commit, so
    /// a dropped phase would strand it.  These go reliable like every other
    /// input message, and the Mac releases Command on disconnect regardless.
    func sendAppSwitcher(_ phase: AppSwitcherPhase) {
        guard isControllable else {
            latestAction = "Pair before switching apps"
            return
        }
        do {
            try sendApplication(.appSwitcher(AppSwitcherPayload(phase: phase)))
            latestAction = "App switcher \(phase)"
            IPhoneDebugLog.emit("app_switcher", ["phase": "\(phase)"])
        } catch {
            latestAction = "App switcher send failed"
        }
    }

    func sendHotkey(_ hotkey: RemoteHotkey) {
        guard isControllable else {
            latestAction = "Pair before using hotkeys"
            return
        }
        keyboard.send(hotkey)
    }

    private func sendKeyboardOutput(_ output: KeyboardOutput) {
        do {
            try sendApplication(try SharedKeyboardProtocolAdapter.payload(for: output))
            switch output {
            case .text:
                latestAction = "Typing"
            case let .hotkey(hotkey):
                latestAction = "Sent \(hotkey.buttonTitle)"
                IPhoneDebugLog.emit("hotkey", ["name": hotkey.rawValue])
            }
        } catch {
            latestAction = "Keyboard send failed"
        }
    }

    private var isControllable: Bool {
        authenticatedSession != nil && peripheral.state == .ready
    }

    private func sendTrackpadOutput(_ output: TrackpadOutput) {
        let label: String
        switch output {
        case .pointer: label = "Trackpad pointer"
        case .scroll: label = "Trackpad scroll"
        case .leftClick: label = "Left click"
        case .rightClick: label = "Right click"
        case .doubleClick: label = "Double click"
        case .dragBegan: label = "Drag began"
        case .dragEnded: label = "Drag ended"
        }
        // Republishing the same label re-rendered the surface on every packet.
        if latestAction != label { latestAction = label }

        switch output {
        case let .pointer(delta):
            pendingPointerX += Int(delta.x)
            pendingPointerY += Int(delta.y)
            flushCursorStream()
        case let .scroll(delta):
            pendingScrollX += Int(delta.x.rounded())
            pendingScrollY += Int(delta.y.rounded())
            flushCursorStream()
        case .leftClick, .rightClick, .doubleClick, .dragBegan, .dragEnded:
            // A button must never land ahead of the travel that preceded it.
            flushCursorStream(force: true)
            do {
                for payload in try SharedTrackpadProtocolAdapter.payloads(for: output) {
                    try sendApplication(payload)
                }
            } catch {
                latestAction = "Trackpad send failed"
            }
        }
    }

    /// Sends the accumulated cursor travel as one compact binary frame.  When
    /// the radio has no room the sum is kept rather than dropped, so the cursor
    /// ends up where the finger is instead of undershooting and then catching
    /// up when the backlog drains.  `force` queues the frame so a click that
    /// follows it cannot overtake it.
    private func flushCursorStream(force: Bool = false) {
        var items: [PointerStreamItem] = []
        if pendingPointerX != 0 || pendingPointerY != 0 {
            items.append(PointerStreamItem(
                kind: .pointer,
                deltaX: clampedInt16(pendingPointerX),
                deltaY: clampedInt16(pendingPointerY)
            ))
        }
        if pendingScrollX != 0 || pendingScrollY != 0 {
            items.append(PointerStreamItem(
                kind: .scroll,
                deltaX: clampedInt16(pendingScrollX),
                deltaY: clampedInt16(pendingScrollY)
            ))
        }
        guard !items.isEmpty else { return }
        guard let session = authenticatedSession, peripheral.state == .ready else {
            clearPendingCursor()
            return
        }
        do {
            let messageID = nextHandshakeMessageID
            nextHandshakeMessageID = messageID == UInt32.max ? 1 : messageID &+ 1
            let frames = try session.wrapBinary(
                try PointerStreamFrame(items: items).encode(),
                messageType: MessageType.pointerDelta.rawValue,
                messageID: messageID,
                maximumValueLength: peripheral.maximumUpdateValueLength,
                reliable: false
            )
            // A message that does not fit one notification must go whole or not
            // at all, so it queues; only the single-frame case can be retried.
            let mustQueue = force || frames.count > 1
            for (index, frame) in frames.enumerated() {
                let deliver = mustQueue || index > 0
                switch peripheral.send(frame, on: .data, enqueue: deliver) {
                case .sent, .queued:
                    continue
                case .queueFull where !deliver:
                    return
                case .queueFull, .notReady, .unsupportedChannel:
                    clearPendingCursor()
                    return
                }
            }
            clearPendingCursor()
        } catch {
            clearPendingCursor()
            latestAction = "Trackpad send failed"
        }
    }

    private func clearPendingCursor() {
        pendingPointerX = 0
        pendingPointerY = 0
        pendingScrollX = 0
        pendingScrollY = 0
    }

    private func clampedInt16(_ value: Int) -> Int16 {
        Int16(min(max(value, Int(Int16.min)), Int(Int16.max)))
    }
}

/// Lets lifecycle reconnect hooks read pairing state without capturing `self` in `init`.
private final class PairingConfirmFlag {
    var value = false
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

private struct RemoteKeyboardSurface: UIViewRepresentable {
    let onText: (String) -> Void
    let onHotkey: (RemoteHotkey) -> Void

    func makeUIView(context: Context) -> RemoteKeyboardCaptureView {
        let view = RemoteKeyboardCaptureView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: RemoteKeyboardCaptureView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: RemoteKeyboardCaptureView) {
        view.onText = onText
        view.onReturn = { onHotkey(.return) }
        view.onDeleteBackward = { onHotkey(.deleteBackward) }
    }
}

extension RemoteHotkey {
    var buttonTitle: String {
        switch self {
        case .escape: return "esc"
        case .return: return "return"
        case .deleteBackward: return "delete"
        case .copy: return "copy"
        case .paste: return "paste"
        case .undo: return "undo"
        case .redo: return "redo"
        case .selectAll: return "all"
        case .tab: return "tab"
        case .arrowUp: return "up"
        case .arrowDown: return "down"
        case .arrowLeft: return "left"
        case .arrowRight: return "right"
        }
    }

    var spokenName: String {
        switch self {
        case .escape: return "Escape"
        case .return: return "Return"
        default: return buttonTitle
        }
    }
}

/// The hotkeys that sit beside the trackpad.  They are the same allowlisted
/// atomic actions the protocol already carries; no key script is possible.
private struct HotkeyBar: View {
    let send: (RemoteHotkey) -> Void
    let switcher: (AppSwitcherPhase) -> Void

    var body: some View {
        HStack(spacing: 8) {
            key(.escape) { Text(RemoteHotkey.escape.buttonTitle) }
            AppSwitcherButton(send: switcher)
            key(.return) { Image(systemName: "return") }
        }
    }

    private func key<Label: View>(_ hotkey: RemoteHotkey, @ViewBuilder label: () -> Label) -> some View {
        Button(action: { send(hotkey) }, label: label)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel(hotkey.spokenName)
    }
}

/// Hold to open the Mac's app switcher, slide to walk along it, lift to pick.
/// A plain tap is the ordinary flip to the last app, because begin already
/// highlights it.
private struct AppSwitcherButton: View {
    /// Roughly a thumb's width of travel per app, so a small wobble while
    /// holding does not step.
    private static let stepWidth: Double = 44

    let send: (AppSwitcherPhase) -> Void
    @State private var isHeld = false
    @State private var steps = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Text("⌘⇥")
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .background(isHeld ? Color.accentColor : Color(.secondarySystemFill))
            .foregroundStyle(isHeld ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isHeld {
                            isHeld = true
                            steps = 0
                            send(.begin)
                        }
                        step(to: Int((value.translation.width / Self.stepWidth).rounded(.towardZero)))
                    }
                    .onEnded { _ in finish(.commit) }
            )
            // A system interruption cancels the gesture without an end, and the
            // Mac would be left holding Command until the watchdog fires.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { finish(.cancel) }
            }
            .accessibilityLabel("App switcher. Hold and slide to choose.")
    }

    private func step(to target: Int) {
        while steps < target {
            steps += 1
            send(.next)
        }
        while steps > target {
            steps -= 1
            send(.previous)
        }
    }

    private func finish(_ phase: AppSwitcherPhase) {
        guard isHeld else { return }
        isHeld = false
        steps = 0
        send(phase)
    }
}

struct PhoneRemoteControlView: View {
    @StateObject private var model = PhoneRemoteFeatureModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            RemoteControlTab(model: model)
                .tabItem { Label("Control", systemImage: "cursorarrow.rays") }
            RemoteSettingsTab(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear { model.scenePhaseChanged(.active) }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            model.pulseAdvertisingIfNeeded()
        }
    }
}

private struct RemoteControlTab: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case trackpad = "Trackpad"
        case airMouse = "Air Mouse"
        case keyboard = "Keyboard"

        var id: Self { self }
    }

    @ObservedObject var model: PhoneRemoteFeatureModel
    @State private var mode: Mode = .trackpad

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
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
                        Text("Tap, two-finger tap, double tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }

                    HotkeyBar(
                        send: { model.sendHotkey($0) },
                        switcher: { model.sendAppSwitcher($0) }
                    )
                } else if mode == .keyboard {
                    RemoteKeyboardSurface(
                        onText: { model.typeText($0) },
                        onHotkey: { model.sendHotkey($0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        Text("Type here. Keys go straight to the Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }

                    HotkeyBar(
                        send: { model.sendHotkey($0) },
                        switcher: { model.sendAppSwitcher($0) }
                    )
                } else {
                    AirMouseClutchButton { held in
                        model.airMouseChanged(held)
                    }
                    Text(model.airMouseStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                PushToTalkButton(controller: model.pushToTalk)
            }
            .padding()
        }
    }
}

private struct RemoteSettingsTab: View {
    @ObservedObject var model: PhoneRemoteFeatureModel
    @ObservedObject private var debugLog = IPhoneDebugLog.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing") {
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
                            .listRowInsets(EdgeInsets())

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
                            .frame(maxWidth: .infinity)
                        } else {
                            Button("Cancel scanner") { model.cancelPairing() }
                        }
                    } else {
                        Button("Scan Mac QR Code") { model.startPairing() }
                        Button(model.isPaired ? "Ping Mac" : "Ping Mac (waiting)") {
                            model.sendPing()
                        }
                    }

                    LabeledContent("Bluetooth", value: model.bluetoothState.label)
                    if let trustedMacName = model.trustedMacName {
                        LabeledContent("Trusted Mac", value: trustedMacName)
                    }
                    Text(model.latestAction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Trackpad sensitivity") {
                    VStack(alignment: .leading) {
                        Text("Horizontal \(model.trackpadSensitivityX.formatted(.number.precision(.fractionLength(1))))x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.trackpadSensitivityX },
                                set: { model.setTrackpadSensitivity(x: $0) }
                            ),
                            in: 0.5...6,
                            step: 0.1
                        )
                    }
                    VStack(alignment: .leading) {
                        Text("Vertical \(model.trackpadSensitivityY.formatted(.number.precision(.fractionLength(1))))x")
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
                    }
                }

                Section("Air mouse sensitivity") {
                    VStack(alignment: .leading) {
                        Text("Pointer speed \(Int(model.airMouseSensitivity))")
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
                    }
                }

                Section("Debug log") {
                    if debugLog.lines.isEmpty {
                        Text("No events yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(debugLog.lines.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 220)
                    }
                }
            }
            .navigationTitle("Settings")
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
