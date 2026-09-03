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
    @Published var airMouseStatus = "Air mouse off"
    @Published var airMouseEnabled = UserDefaults.standard.bool(forKey: "airMouseEnabled")
    @Published var airMouseSensitivity = UserDefaults.standard.object(forKey: "airMouseSensitivity") as? Double ?? 2_400
    @Published var appSwitcherSensitivity = UserDefaults.standard.object(forKey: "appSwitcherSensitivity") as? Double ?? 2.0
    @Published var trackpadSensitivityX = UserDefaults.standard.object(forKey: "trackpadSensitivityX") as? Double ?? 1.0
    @Published var trackpadSensitivityY = UserDefaults.standard.object(forKey: "trackpadSensitivityY") as? Double ?? 1.0
    @Published var trackpadScrollSensitivity = UserDefaults.standard.object(forKey: "trackpadScrollSensitivity") as? Double ?? 1.0
    @Published var scrollMomentum = UserDefaults.standard.object(forKey: "scrollMomentum") as? Double ?? TrackpadTouchCaptureView.defaultMomentumStrength
    @Published var pairingState: IPhonePairingScannerState = .idle
    @Published var bluetoothState: BLEPeripheralLifecycleState = .idle
    @Published var trustedMacName: String?
    /// Round trip over Bluetooth, measured end to end from this app.
    @Published var linkLatency = "Not measured"


    private static let pingBurstCount = 5
    private var pingSentAt: [TimeInterval] = []
    private var pingSamples: [Double] = []

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
    private let cursorMixer = CursorMixer()
    private let inputLink: BLEInputLink
    private let inputUplink: InputUplink
    /// The trackpad surface is the only screen the air mouse runs on.
    private var trackpadVisible = false
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
        didSet {
            voiceUplink.setSession(authenticatedSession, maximumValueLength: peripheral.maximumUpdateValueLength)
            inputLink.setSession(authenticatedSession)
            if authenticatedSession == nil { inputUplink.reset() }
            refreshAirMouse()
        }
    }
    private var inboundReassembler: BLEReassembler?
    private var controlReassembler: BLEReassembler?
    private var nextHandshakeMessageID: UInt32 = 1
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
        let inputLink = BLEInputLink(peripheral: peripheral)
        self.inputLink = inputLink
        inputUplink = InputUplink(link: inputLink)
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
        motionSink.onFlush = { [weak self] delta in
            // The coalescer is the hop from the Core Motion queue to this one,
            // and it already lands here. A second Task hop queued every sample
            // and the cursor lagged more the longer the air mouse ran.
            MainActor.assumeIsolated {
                self?.handleMotionDelta(delta)
            }
        }
        cursorMixer.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                self?.sendInputEvent(event)
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
        refreshAirMouse()
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
            refreshAirMouse()
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

    func setAirMouseEnabled(_ enabled: Bool) {
        airMouseEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "airMouseEnabled")
        refreshAirMouse()
        latestAction = airMouseStatus
    }

    /// The air mouse only tracks while the trackpad surface is on screen, so
    /// the settings and pairing screens cannot move the cursor.
    func setTrackpadVisible(_ visible: Bool) {
        guard trackpadVisible != visible else { return }
        trackpadVisible = visible
        refreshAirMouse()
    }

    private func refreshAirMouse() {
        guard airMouseEnabled else {
            _ = motionSession.setClutchHeld(false)
            airMouseStatus = "Air mouse off"
            return
        }
        guard isControllable else {
            _ = motionSession.setClutchHeld(false)
            airMouseStatus = "Pair before using air mouse"
            return
        }
        guard trackpadVisible else {
            _ = motionSession.setClutchHeld(false)
            airMouseStatus = "Air mouse starts on the trackpad"
            return
        }
        switch motionSession.setClutchHeld(true) {
        case .started:
            airMouseStatus = "Air mouse active"
        case .unavailable:
            airMouseStatus = "This phone has no motion sensor"
        case .inactive, .none:
            airMouseStatus = "Air mouse waits for the app"
        case .failed:
            airMouseStatus = "Air mouse could not start"
        }
    }

    func setAppSwitcherSensitivity(_ value: Double) {
        appSwitcherSensitivity = value
        UserDefaults.standard.set(value, forKey: "appSwitcherSensitivity")
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
                refreshAirMouse()
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

    /// A burst rather than a single ping, because one sample cannot tell a
    /// typical hop from one that waited out a slow connection slot. Pongs carry
    /// no identifier, so they are matched to sends in order; the spacing is far
    /// wider than the round trip, which keeps that honest.
    func sendPing() {
        guard isControllable else {
            latestAction = "Pair first"
            return
        }
        pingSamples.removeAll()
        pingSentAt.removeAll()
        linkLatency = "Measuring…"
        latestAction = "Measuring link"
        for index in 0..<Self.pingBurstCount {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(index * 250))
                self?.sendOnePing()
            }
        }
    }

    private func sendOnePing() {
        guard isControllable else { return }
        pingSentAt.append(ProcessInfo.processInfo.systemUptime)
        guard inputUplink.send(.ping(PingPayload())) else {
            pingSentAt.removeLast()
            latestAction = "Ping failed"
            return
        }
        IPhoneDebugLog.emit("ping_sent", ["ble": bluetoothState.label])
    }

    private func recordPong() {
        guard !pingSentAt.isEmpty else { return }
        let sent = pingSentAt.removeFirst()
        let roundTrip = (ProcessInfo.processInfo.systemUptime - sent) * 1_000
        pingSamples.append(roundTrip)
        let best = pingSamples.min() ?? roundTrip
        let average = pingSamples.reduce(0, +) / Double(pingSamples.count)
        linkLatency = String(
            format: "%.0f ms average, %.0f ms best, %d of %d",
            average,
            best,
            pingSamples.count,
            Self.pingBurstCount
        )
        IPhoneDebugLog.emit("ping_rtt", ["ms": String(format: "%.1f", roundTrip)])
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
                    recordPong()
                    latestAction = "Pong from Mac"
                }
            }
        } catch {
            latestAction = "Link check failed"
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

    /// Air-mouse travel enters the pipeline at the mixer, the same door the
    /// trackpad uses.  Everything after that point is shared, so the two
    /// sensors cannot each spend a full packet budget.
    func handleMotionDelta(_ delta: MotionPointerDelta) {
        guard isControllable else { return }
        guard delta.x.isFinite, delta.y.isFinite else {
            airMouseStatus = "Air mouse send failed"
            return
        }
        cursorMixer.handleTravel(CursorDelta(x: delta.x, y: delta.y))
    }

    func setTrackpadSensitivity(x: Double? = nil, y: Double? = nil, scroll: Double? = nil) {
        if let x {
            trackpadSensitivityX = x
            UserDefaults.standard.set(x, forKey: "trackpadSensitivityX")
        }
        if let y {
            trackpadSensitivityY = y
            UserDefaults.standard.set(y, forKey: "trackpadSensitivityY")
        }
        if let scroll {
            trackpadScrollSensitivity = scroll
            UserDefaults.standard.set(scroll, forKey: "trackpadScrollSensitivity")
        }
    }

    func setScrollMomentum(_ value: Double) {
        scrollMomentum = value
        UserDefaults.standard.set(value, forKey: "scrollMomentum")
    }

    func handleRemoteInputEvents(_ events: [RemoteInputEvent]) {
        guard isControllable else { return }
        cursorMixer.handle(events)
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
        guard inputUplink.send(.appSwitcher(AppSwitcherPayload(phase: phase))) else {
            latestAction = "App switcher send failed"
            return
        }
        latestAction = "App switcher \(phase)"
        IPhoneDebugLog.emit("app_switcher", ["phase": "\(phase)"])
    }

    func sendHotkey(_ hotkey: RemoteHotkey) {
        guard isControllable else {
            latestAction = "Pair before using hotkeys"
            return
        }
        keyboard.send(hotkey)
    }

    private func sendKeyboardOutput(_ output: KeyboardOutput) {
        guard let payload = try? SharedKeyboardProtocolAdapter.payload(for: output),
              inputUplink.send(payload) else {
            latestAction = "Keyboard send failed"
            return
        }
        switch output {
        case .text:
            latestAction = "Typing"
        case let .hotkey(hotkey):
            latestAction = "Sent \(hotkey.buttonTitle)"
            IPhoneDebugLog.emit("hotkey", ["name": hotkey.rawValue])
        }
    }

    private var isControllable: Bool { inputUplink.isReady }

    /// The label is the only part of an input event the model still cares
    /// about.  Packing, ordering, and the busy link belong to the uplink.
    private func sendInputEvent(_ event: RemoteInputEvent) {
        let label: String
        switch event {
        case .pointer: label = "Cursor move"
        case .scroll: label = "Trackpad scroll"
        case .leftClick: label = "Left click"
        case .rightClick: label = "Right click"
        case .doubleClick: label = "Double click"
        case .dragBegan: label = "Drag began"
        case .dragEnded: label = "Drag ended"
        case .missionControl: label = "Mission Control"
        case .appExpose: label = "App windows"
        }
        // Republishing the same label re-rendered the surface on every packet.
        if latestAction != label { latestAction = label }
        let sent = inputUplink.send(event)
        if !sent { latestAction = "Cursor send failed" }
        switch event {
        case .missionControl: IPhoneDebugLog.emit("mission_control", ["sent": "\(sent)"])
        case .appExpose: IPhoneDebugLog.emit("app_expose", ["sent": "\(sent)"])
        default: break
        }
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

private struct AppSwitcherTouchSurface: UIViewRepresentable {
    let onPhase: (HoldSlidePhase) -> Void

    func makeUIView(context: Context) -> HoldSlideCaptureView {
        let view = HoldSlideCaptureView(frame: .zero)
        view.label = "app_switcher"
        view.onPhase = onPhase
        return view
    }

    func updateUIView(_ uiView: HoldSlideCaptureView, context: Context) {
        uiView.onPhase = onPhase
    }
}

private struct TrackpadSurface: UIViewRepresentable {
    let pointerSensitivityX: Double
    let pointerSensitivityY: Double
    let scrollSensitivity: Double
    let momentumStrength: Double
    let onOutputs: ([RemoteInputEvent]) -> Void

    func makeUIView(context: Context) -> TrackpadTouchCaptureView {
        let view = TrackpadTouchCaptureView(frame: .zero)
        view.onOutputs = onOutputs
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TrackpadTouchCaptureView, context: Context) {
        uiView.onOutputs = onOutputs
        apply(to: uiView)
    }

    private func apply(to view: TrackpadTouchCaptureView) {
        view.engine.setSensitivity(
            pointerX: pointerSensitivityX,
            pointerY: pointerSensitivityY,
            scroll: scrollSensitivity
        )
        view.momentumStrength = momentumStrength
    }
}

/// An invisible responder.  It carries no size of its own; showing it is only
/// a matter of taking the responder, which raises the system keyboard and lets
/// the layout below shrink around it while the trackpad stays live.
private struct RemoteKeyboardSurface: UIViewRepresentable {
    @Binding var isShowing: Bool
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
        // The button follows the responder, so a keyboard the system takes
        // away still leaves the toggle telling the truth.
        view.onActiveChange = { active in
            DispatchQueue.main.async {
                if isShowing != active { isShowing = active }
            }
        }
        let wanted = isShowing
        // The view is not in a window yet during make, and changing the
        // responder inside a SwiftUI update is not allowed.
        DispatchQueue.main.async {
            if wanted {
                view.becomeFirstResponder()
            } else {
                view.resignFirstResponder()
            }
        }
    }
}

extension RemoteHotkey {
    var buttonTitle: String {
        switch self {
        case .escape: return "esc"
        case .return: return "return"
        case .deleteBackward: return "delete"
        case .deleteWordBackward: return "⌥⌫"
        case .deleteLineBackward: return "⌘⌫"
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
        case .deleteBackward: return "Backspace"
        case .deleteWordBackward: return "Backspace word"
        case .deleteLineBackward: return "Backspace line"
        default: return buttonTitle
        }
    }
}

/// The hotkeys that sit beside the trackpad.  They are the same allowlisted
/// atomic actions the protocol already carries; no key script is possible.
private struct HotkeyBar: View {
    let send: (RemoteHotkey) -> Void
    let switcherSensitivity: Double
    let switcher: (AppSwitcherPhase) -> Void

    var body: some View {
        HStack(spacing: 8) {
            key(.escape) { Text(RemoteHotkey.escape.buttonTitle) }
            AppSwitcherButton(sensitivity: switcherSensitivity, send: switcher)
            key(.return) { Image(systemName: "return") }
            key(.deleteBackward) { Image(systemName: "delete.left") }
            key(.deleteWordBackward) { Text(RemoteHotkey.deleteWordBackward.buttonTitle) }
            key(.deleteLineBackward) { Text(RemoteHotkey.deleteLineBackward.buttonTitle) }
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
    /// Travel per app at 1x.  Roughly a thumb's width, so a wobble while
    /// holding does not step; the sensitivity setting divides it.
    static let baseStepWidth: Double = 44

    let sensitivity: Double
    let send: (AppSwitcherPhase) -> Void
    @State private var isHeld = false
    @State private var steps = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Text("⌘⇥")
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isHeld ? Color.accentColor : Color(.secondarySystemFill))
            .foregroundStyle(isHeld ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Touches come from UIKit, not from a SwiftUI gesture.  The
            // gesture sat on a press for 100 ms at best and 780 ms after an
            // idle spell, which was most of what this button felt like.
            .overlay(AppSwitcherTouchSurface(onPhase: handle))
            // A system interruption cancels the gesture without an end, and the
            // Mac would be left holding Command until the watchdog fires.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { finish(.cancel) }
            }
            .accessibilityLabel("App switcher. Hold and slide to choose.")
    }

    private var stepWidth: Double {
        Self.baseStepWidth / min(max(sensitivity, 0.5), 4)
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            guard !isHeld else { return }
            isHeld = true
            steps = 0
            send(.begin)
        case let .moved(translationX):
            guard isHeld else { return }
            step(to: Int((translationX / stepWidth).rounded(.towardZero)))
        case .ended:
            finish(.commit)
        case .cancelled:
            finish(.cancel)
        }
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
    @ObservedObject var model: PhoneRemoteFeatureModel
    @State private var isKeyboardShowing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TrackpadSurface(
                    pointerSensitivityX: model.trackpadSensitivityX,
                    pointerSensitivityY: model.trackpadSensitivityY,
                    scrollSensitivity: model.trackpadScrollSensitivity,
                    momentumStrength: model.scrollMomentum
                ) { outputs in
                    model.handleRemoteInputEvents(outputs)
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
                    switcherSensitivity: model.appSwitcherSensitivity,
                    switcher: { model.sendAppSwitcher($0) }
                )

                ZStack(alignment: .bottomTrailing) {
                    PushToTalkButton(controller: model.pushToTalk)
                        .frame(maxWidth: .infinity)
                    KeyboardToggleButton(isShowing: $isKeyboardShowing)
                }
                .overlay(alignment: .bottom) {
                    RemoteKeyboardSurface(
                        isShowing: $isKeyboardShowing,
                        onText: { model.typeText($0) },
                        onHotkey: { model.sendHotkey($0) }
                    )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                }
            }
            .padding()
            .onAppear { model.setTrackpadVisible(true) }
            .onDisappear {
                isKeyboardShowing = false
                model.setTrackpadVisible(false)
            }
        }
    }
}

/// Sits in the bottom right corner beside push to talk.  It only opens and
/// closes the system keyboard; the trackpad above stays live either way.
private struct KeyboardToggleButton: View {
    @Binding var isShowing: Bool

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: isShowing ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.title3)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .background(isShowing ? Color.accentColor : Color(.secondarySystemFill))
        .foregroundStyle(isShowing ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(isShowing ? "Hide keyboard" : "Show keyboard")
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
                    LabeledContent("Link round trip", value: model.linkLatency)
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

                Section {
                    VStack(alignment: .leading) {
                        Text("Slide sensitivity \(model.appSwitcherSensitivity.formatted(.number.precision(.fractionLength(1))))x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.appSwitcherSensitivity },
                                set: { model.setAppSwitcherSensitivity($0) }
                            ),
                            in: 0.5...4,
                            step: 0.1
                        )
                        Text("One app per \(Int((AppSwitcherButton.baseStepWidth / model.appSwitcherSensitivity).rounded())) points of slide")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("App switcher")
                } footer: {
                    Text("How far you slide sideways, holding the app switcher button, to move one app.")
                }

                Section("Scrolling") {
                    VStack(alignment: .leading) {
                        Text("Scroll speed \(model.trackpadScrollSensitivity.formatted(.number.precision(.fractionLength(1))))x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.trackpadScrollSensitivity },
                                set: { model.setTrackpadSensitivity(scroll: $0) }
                            ),
                            in: 0.5...6,
                            step: 0.1
                        )
                    }
                    VStack(alignment: .leading) {
                        Text(model.scrollMomentum == 0
                             ? "Glide after a flick: off"
                             : "Glide after a flick \(Int(model.scrollMomentum * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.scrollMomentum },
                                set: { model.setScrollMomentum($0) }
                            ),
                            in: 0...1,
                            step: 0.05
                        )
                    }
                }

                Section {
                    Toggle(
                        "Point the phone to move the cursor",
                        isOn: Binding(
                            get: { model.airMouseEnabled },
                            set: { model.setAirMouseEnabled($0) }
                        )
                    )
                    Text(model.airMouseStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .disabled(!model.airMouseEnabled)
                } header: {
                    Text("Air mouse")
                } footer: {
                    Text("Works on the Trackpad screen. Tap the trackpad to click while you aim.")
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
