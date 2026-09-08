import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

#if os(iOS)
import AVFoundation
import UIKit

private extension RemoteLinkState {
    var label: String {
        switch self {
        case .unavailable: return "Off"
        case .searching: return "Waiting for Mac"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }
}

/// A deliberately small view model for the prototype UI.  It owns the local
/// push-to-talk and motion sessions, but it does not invent a second transport
/// path: feature adapters continue to emit the shared protocol payloads the
/// link carries.
@MainActor
final class NewMotionFeatureModel: ObservableObject {
    private static let trustedDeviceService = "com.davidliao.newmotion.ios.trusted-devices"

    @Published var latestAction = "Not paired"
    @Published var isPaired = false
    @Published var airMouseStatus = "Air mouse off"
    @Published var airMouseEnabled = UserDefaults.standard.bool(forKey: "airMouseEnabled")
    @Published var airMouseSensitivity = UserDefaults.standard.object(forKey: "airMouseSensitivity") as? Double ?? 2_400
    @Published var voiceBoostWords = UserDefaults.standard.string(forKey: "voiceBoostWords") ?? ""
    @Published var onDeviceVoiceStatus = OnDeviceVoiceReadiness.preparing.label
    /// The words heard so far in the utterance under way, shown on the remote
    /// and cleared when it ends. Never logged and never stored.
    @Published var voicePreview = ""
    /// The Mac's screen vocabulary, as last pushed. Not persisted: it belongs
    /// to whatever is on that screen now, not to this app's settings.
    private var macVocabulary: [String] = []
    @Published var layoutMode = RemoteLayoutMode(
        rawValue: UserDefaults.standard.string(forKey: "remoteLayoutMode") ?? ""
    ) ?? .vertical
    @Published var mirrorHorizontalLayout = UserDefaults.standard.bool(forKey: "mirrorHorizontalLayout")
    @Published var trackpadSensitivityX = UserDefaults.standard.object(forKey: "trackpadSensitivityX") as? Double ?? 3.0
    @Published var trackpadSensitivityY = UserDefaults.standard.object(forKey: "trackpadSensitivityY") as? Double ?? 4.0
    @Published var trackpadScrollSensitivity = UserDefaults.standard.object(forKey: "trackpadScrollSensitivity") as? Double ?? 2.0
    @Published var scrollMomentum = UserDefaults.standard.object(forKey: "scrollMomentum") as? Double ?? TrackpadTouchCaptureView.defaultMomentumStrength
    @Published var pairingState: IPhonePairingScannerState = .idle
    /// The Mac whose user has yet to allow this phone. Drives the waiting
    /// spinner from the moment the code is scanned until the Mac answers.
    @Published private(set) var awaitingMacName: String?
    @Published private(set) var linkState: RemoteLinkState = .unavailable
    @Published private(set) var trustedMacs: [TrustedDeviceSummary] = []
    @Published private(set) var selectedMacID: UUID? = UserDefaults.standard.string(forKey: "selectedMacID").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(selectedMacID?.uuidString, forKey: "selectedMacID") }
    }
    /// The Mac this phone reaches for: the chosen one, else the newest pairing.
    var selectedMac: TrustedDeviceSummary? {
        trustedMacs.first { $0.deviceID == selectedMacID } ?? trustedMacs.max { $0.pairedAt < $1.pairedAt }
    }
    var trustedMacName: String? { selectedMac?.displayName }
    /// Round trip over the link, measured end to end from this app.
    @Published var linkLatency = "Not measured"

    /// What the connection is doing, in words the settings screen can show.
    var linkStatus: String { linkState.label }

    private static let pingBurstCount = 5
    /// How often the phone pings on its own, and how long the summary line
    /// covers.  Both are slow enough that neither costs the link anything.
    private static let autoPingInterval: TimeInterval = 2
    private static let latencySummaryInterval: TimeInterval = 5
    /// A pong that has not come back by now never will.
    private static let pingTimeout: TimeInterval = 3
    private static let maxOutstandingPings = 8
    /// Sends still waiting for a pong, oldest first.
    private var pingSentAt: [TimeInterval] = []
    private var pingSamples: [Double] = []
    /// Pongs still owed to a manual burst.  A burst owns the on-screen number
    /// and the per-ping log lines; the automatic ping is silent.
    private var pingBurstRemaining = 0
    private var telemetryTimers: [Timer] = []
    private var isForeground = false

    private let audioController: LocalPushToTalkAudioController
    private(set) lazy var pushToTalk = PushToTalkController(
        audio: audioController,
        activity: { [weak self] in self?.latestAction = $0 },
        logContext: { [weak self] in
            [
                "link": self?.linkState.label ?? "unknown",
                "auth": self?.authenticatedSession != nil ? "yes" : "no"
            ]
        }
    )
    private let motionSink: DeltaCoalescer<MotionPointerDelta>
    private let cursorMixer = CursorMixer()
    private var oneFingerScrolling = false
    /// The air mouse has no finger to flick, so its scroll coasts off the same
    /// curve as the trackpad's, released when the finger leaves the strip.
    private let airScrollMomentum = ScrollMomentumDriver()
    private let inputLink: SessionInputLink
    private let inputUplink: InputUplink
    /// The trackpad surface is the only screen the air mouse runs on.
    private var trackpadVisible = false
    private lazy var keyboardForwarder = KeyboardOutputForwarder { [weak self] output in
        self?.sendKeyboardOutput(output)
    }
    private lazy var keyboard = KeyboardInputController(sink: keyboardForwarder)
    private let motionSession: MotionPointerSession
    private let link: MessageLink
    private let lifecycle: PhoneLifecycleCoordinator
    let pairingCapture: AVFoundationQRCodeCaptureAdapter
    private let pairingScanner: IPhonePairingScanner
    private let pairingCoordinator: IPhonePairingCoordinator?
    private var pairingClient: PairingHandshakeClient?
    private var pairingToken: PairingToken?
    private var authenticatedSession: PairingSession? {
        didSet {
            inputLink.setSession(authenticatedSession)
            if authenticatedSession == nil { inputUplink.reset() }
            refreshAirMouse()
        }
    }
    private var handshakeHelloSent = false
    private let pairingConfirmFlag = PairingConfirmFlag()
    private var pairingConfirmed: Bool {
        get { pairingConfirmFlag.value }
        set { pairingConfirmFlag.value = newValue }
    }
    private var trustedPeer: TrustedDeviceSummary?
    private var reconnectFailures = 0
    /// Speech becomes text here and travels as text; nothing the microphone
    /// hears ever leaves the phone.
    private let onDeviceVoice = OnDeviceVoice()
    private let voiceBoost = VoiceBoostBox()
    private var audioSessionObservers: [NSObjectProtocol] = []

    /// The coordinator is a parameter so a caller can hand in one over its own
    /// trust store; the app's own is the Keychain, which a test cannot reach.
    init(
        link: MessageLink = BLEMessageLink(
            peripheral: IPhoneBLEPeripheralTransport(adapter: CoreBluetoothPeripheralManagerAdapter())
        ),
        pairingCoordinator: IPhonePairingCoordinator? = nil
    ) {
        let audioController = LocalPushToTalkAudioController(
            microphone: AVAudioMicrophoneInput(),
            permissionGranted: AVAudioApplication.shared.recordPermission == .granted
        )
        self.audioController = audioController
        let motionSink = DeltaCoalescer<MotionPointerDelta>.motionPointer()
        self.motionSink = motionSink
        motionSession = MotionPointerSession(
            provider: CoreMotionDeviceProvider(),
            sink: motionSink
        )
        self.link = link
        let inputLink = SessionInputLink(link: link)
        self.inputLink = inputLink
        inputUplink = InputUplink(link: inputLink)
        let confirmFlag = pairingConfirmFlag
        self.lifecycle = PhoneLifecycleCoordinator(
            motion: motionSession,
            audio: audioController,
            disconnectTransport: { link.stop() },
            attemptReconnect: {
                guard confirmFlag.value else { return }
                link.start()
            }
        )
        let capture = AVFoundationQRCodeCaptureAdapter()
        pairingCapture = capture
        pairingScanner = IPhonePairingScanner(
            permission: AVFoundationCameraPermissionAdapter(),
            capture: capture
        )
        self.pairingCoordinator = pairingCoordinator ?? (try? IPhonePairingCoordinator(
            store: KeychainTrustedDeviceStore(service: Self.trustedDeviceService)
        ))
        _ = lifecycle.handle(.startup)

        link.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleLinkState(state) }
        }
        link.onMessage = { [weak self] channel, message in
            Task { @MainActor [weak self] in self?.handleMessage(channel: channel, message: message) }
        }
        link.onError = { [weak self] error in
            Task { @MainActor [weak self] in self?.handleLinkError(error) }
        }
        pairingScanner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.pairingState = state
            }
        }
        if let pairingCoordinator = self.pairingCoordinator {
            pairingCoordinator.onPairingReady = { [weak self] token, _, client in
                Task { @MainActor [weak self] in
                    self?.beginPairingHandshake(token: token, client: client)
                }
            }
            pairingCoordinator.attach(scanner: pairingScanner)
        } else {
            pairingScanner.onScanned = { [weak self] _ in
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
        refreshTrustedMacs()
        IPhoneDebugLog.emit("trust", ["count": "\(trustedMacs.count)"])
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
        airScrollMomentum.strength = scrollMomentum
        airScrollMomentum.onStep = { [weak self] delta in
            MainActor.assumeIsolated {
                self?.cursorMixer.handleScrollTravel(CursorDelta(x: 0, y: delta.y))
            }
        }
        let onDevice = onDeviceVoice
        let boost = voiceBoost
        // The audio callbacks arrive on the voice queue, so the boost list is
        // read through its lock rather than off the main actor.
        audioController.onUtteranceStart = { onDevice.begin(boostWords: boost.words) }
        audioController.onChunk = { onDevice.append($0) }
        audioController.onUtteranceEnd = { onDevice.end() }
        audioController.onUtteranceCancel = { [weak self] in
            onDevice.cancel()
            Task { @MainActor in self?.voicePreview = "" }
        }
        onDeviceVoice.onText = { [weak self] text in
            Task { @MainActor in self?.typeTranscribedText(text) }
        }
        onDeviceVoice.onPartialText = { [weak self] text in
            Task { @MainActor in self?.voicePreview = text }
        }
        onDeviceVoice.onReadiness = { [weak self] readiness in
            Task { @MainActor in self?.onDeviceVoiceStatus = readiness.label }
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
        motionSession.updateFilter(motionConfiguration)
        refreshAirMouse()
        refreshVoiceBoost()
        IPhoneDebugLog.emit("app_init", [
            "auth": "\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
            "screenCaptured": UIScreen.main.isCaptured ? "yes" : "no"
        ])
    }

    var isPairingVisible: Bool {
        switch pairingState {
        case .scanning, .requestingCamera:
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
            "link": linkState.label
        ])
        pairingClient = nil
        pairingToken = nil
        handshakeHelloSent = false
        pairingConfirmed = false
        awaitingMacName = nil
        authenticatedSession = nil
        isPaired = false
        pairingState = pairingScanner.beginQRPairingScan { [weak self] in
            guard let self else { return }
            IPhoneDebugLog.emit("camera_live", ["link": self.linkState.label])
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

    /// Covers both the open scanner and the wait for the Mac's answer.
    func cancelPairing() {
        pairingScanner.cancel()
        pairingState = pairingScanner.state
        if awaitingMacName != nil { abandonOneTimePairing() }
        latestAction = "Pairing cancelled"
        resumeReconnectIfNeeded()
    }

    /// Ends a one-time pairing that never produced a session, leaving the
    /// phone free to reconnect to a Mac it already trusts.
    private func abandonOneTimePairing() {
        pairingClient = nil
        pairingToken = nil
        handshakeHelloSent = false
        pairingConfirmed = false
        awaitingMacName = nil
        link.stop()
    }

    private func resumeReconnectIfNeeded() {
        guard authenticatedSession == nil else { return }
        if pairingCoordinator?.trustedDevices.isEmpty == false {
            beginTrustedReconnect()
        }
    }

    private func refreshTrustedMacs() {
        trustedMacs = pairingCoordinator?.trustedDevices ?? []
    }

    /// Dropping the session is what makes the current Mac let go; the beacon
    /// then names the new one before the link comes back up.
    func selectMac(_ id: UUID) {
        // The picker shows `selectedMac`, which falls back to the newest
        // pairing while nothing has been chosen, so re-picking the Mac already
        // in use arrives here as a change. Record the choice, but do not drop a
        // live session over it.
        let alreadyInUse = id == selectedMac?.deviceID
        selectedMacID = id
        if !alreadyInUse, authenticatedSession != nil || pairingClient != nil {
            authenticatedSession = nil
            pairingClient = nil
            handshakeHelloSent = false
            awaitingMacName = nil
            link.stop()
        }
        // Still worth a reconnect when the row was already ticked: tapping the
        // Mac you are on is how someone retries a link that is down. It is a
        // no-op while a session is up.
        beginTrustedReconnect()
    }

    /// The camera can come up black, so an open scanner says every few seconds
    /// whether frames are still arriving.
    func logPairingDiagnostics() {
        guard isPairingVisible else { return }
        var fields = pairingCapture.diagnostics()
        fields["pairing"] = "\(pairingState)"
        fields["screenCaptured"] = UIScreen.main.isCaptured ? "yes" : "no"
        IPhoneDebugLog.emit("camera_tick", fields)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            _ = lifecycle.handle(.foreground)
            isForeground = true
            syncTelemetry()
            motionSession.setAppActive(true)
            refreshAirMouse()
            reconnectFailures = 0
            if isPairingVisible {
                // QR scan owns the radio. A saved-Mac reconnect hello would
                // race the new one-time handshake.
                break
            } else if authenticatedSession == nil, pairingCoordinator?.trustedDevices.isEmpty == false {
                beginTrustedReconnect()
            } else if pairingConfirmed {
                link.start()
            } else {
                link.stop()
            }
        case .inactive:
            // Inactive is not background. Stopping the link here takes the
            // beacon down while the user still sees the app, so the Mac never
            // reconnects.
            break
        case .background:
            _ = lifecycle.handle(.background)
            isForeground = false
            syncTelemetry()
            motionSession.setAppActive(false)
        @unknown default:
            _ = lifecycle.handle(.background)
            isForeground = false
            syncTelemetry()
            motionSession.setAppActive(false)
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
        if !airMouseEnabled || !trackpadVisible { airScrollMomentum.stop() }
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
        // The screen may have turned since the last hold, and the tilt axis
        // turns with it.
        motionSession.updateFilter(motionConfiguration)
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

    /// The layout decides which way the screen faces, so picking one turns the
    /// phone rather than waiting for the hand to.
    func setLayoutMode(_ mode: RemoteLayoutMode) {
        layoutMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "remoteLayoutMode")
        InterfaceOrientationLock.apply(mode.orientations)
    }

    func setMirrorHorizontalLayout(_ enabled: Bool) {
        mirrorHorizontalLayout = enabled
        UserDefaults.standard.set(enabled, forKey: "mirrorHorizontalLayout")
    }

    func setVoiceBoostWords(_ raw: String) {
        voiceBoostWords = raw
        UserDefaults.standard.set(raw, forKey: "voiceBoostWords")
        refreshVoiceBoost()
    }

    /// Publishes the boost list to the voice queue and makes sure the model is
    /// on its way down.  Called whenever either half of the list changes: the
    /// Settings field here, or a fresh walk pushed by the Mac.
    private func refreshVoiceBoost() {
        // The Settings field is a permanent extra on top of whatever the Mac
        // can see, so a name you always want heard survives a window change.
        voiceBoost.update(VoiceBoostWords.merge(
            typed: VoiceBoostWords.parse(voiceBoostWords),
            fromMac: macVocabulary
        ))
        guard onDeviceVoice.isSupported else {
            onDeviceVoiceStatus = OnDeviceVoiceReadiness.unsupported.label
            return
        }
        onDeviceVoice.prepare()
    }

    /// A finger in an edge strip turns every sensor's travel into scroll, which
    /// is what makes the air mouse usable as a scroll wheel.  Landing in the
    /// strip stops any glide still running; leaving it starts one.
    func setOneFingerScrolling(_ scrolling: Bool) {
        guard oneFingerScrolling != scrolling else { return }
        oneFingerScrolling = scrolling
        if scrolling {
            airScrollMomentum.stop()
        } else {
            airScrollMomentum.release(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func setAirMouseSensitivity(_ value: Double) {
        airMouseSensitivity = value
        UserDefaults.standard.set(value, forKey: "airMouseSensitivity")
        motionSession.updateFilter(motionConfiguration)
    }

    /// Sensitivity from the setting, tilt axis from the way the screen faces
    /// right now.
    private var motionConfiguration: MotionFilterConfiguration {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        return MotionFilterConfiguration(
            sensitivity: airMouseSensitivity,
            screenOrientation: MotionScreenOrientation(scene?.effectiveGeometry.interfaceOrientation)
        )
    }

    private func handleLinkState(_ state: RemoteLinkState) {
        linkState = state
        syncTelemetry()
        IPhoneDebugLog.emit("link", ["state": state.label])
        switch state {
        case .searching:
            handshakeHelloSent = false
            _ = lifecycle.handle(.transportAvailable)
            if authenticatedSession != nil {
                // The Mac dropped the link (typically its app restarted), and
                // its side of the session went with it; handshake again.
                authenticatedSession = nil
                pairingClient = nil
                IPhoneDebugLog.emit("session_lost", ["link": state.label])
                beginTrustedReconnect()
            }
            if pairingConfirmed, authenticatedSession == nil {
                latestAction = trustedMacName.map { "Reconnecting to \($0)" } ?? "Waiting for Mac to connect"
            }
        case .connecting:
            _ = lifecycle.handle(.transportAvailable)
            if pairingConfirmed, authenticatedSession == nil {
                latestAction = "Connected; preparing authentication"
            }
        case .connected:
            _ = lifecycle.handle(.transportAvailable)
            if authenticatedSession != nil {
                latestAction = "Paired with Mac"
                refreshAirMouse()
            } else if pairingClient != nil {
                sendHandshakeHelloIfNeeded()
            }
        case .unavailable:
            // Deliberately not reported as a lifecycle transport loss: a link
            // that is merely waiting is not one that has gone, and treating it
            // as gone would stop the app ever bringing it back.
            if pairingConfirmed { latestAction = "Waiting for the link" }
        }
    }

    /// A message the link could not put back together, arriving in the middle
    /// of a handshake, is a handshake that will not finish; it starts over
    /// rather than waiting the retry out.
    private func handleLinkError(_ error: LinkError) {
        IPhoneDebugLog.emit("link_error", ["kind": "\(error)"])
        guard error == .malformedMessage, pairingClient != nil, authenticatedSession == nil else { return }
        failPairing()
    }

    private func beginPairingHandshake(token: PairingToken, client: PairingHandshakeClient) {
        pairingConfirmed = true
        pairingToken = token
        pairingClient = client
        authenticatedSession = nil
        handshakeHelloSent = false
        reconnectFailures = 0
        awaitingMacName = token.macDisplayName
        IPhoneDebugLog.emit("handshake_begin", ["link": linkState.label])
        link.setBeacons([NewMotionBeacon.uuid(pairingID: token.pairingID)])
        link.start()
        latestAction = "Waiting for \(token.macDisplayName) to connect"
        sendHandshakeHelloIfNeeded()
    }

    private func beginTrustedReconnect() {
        guard authenticatedSession == nil else { return }
        if pairingClient != nil {
            pairingConfirmed = true
            IPhoneDebugLog.emit("reconnect", ["path": "client", "link": linkState.label])
            // The client belongs to the QR pairing when one is under way,
            // otherwise to the trusted Mac it was made for.
            if let pairingID = pairingToken?.pairingID ?? trustedPeer?.deviceID {
                link.setBeacons([NewMotionBeacon.uuid(pairingID: pairingID)])
            }
            link.start()
            sendHandshakeHelloIfNeeded()
            return
        }
        guard let pairingCoordinator else {
            IPhoneDebugLog.emit("reconnect_skip", ["reason": "no_store"])
            return
        }
        guard let device = selectedMac else {
            IPhoneDebugLog.emit("reconnect_skip", ["reason": "no_trust"])
            return
        }
        do {
            pairingClient = try pairingCoordinator.makeReconnectClient(for: device.deviceID)
            trustedPeer = device
            pairingConfirmed = true
            pairingToken = nil
            handshakeHelloSent = false
            _ = lifecycle.handle(.trustAdded)
            latestAction = "Reconnecting to \(device.displayName)"
            IPhoneDebugLog.emit("reconnect", ["path": "trust", "link": linkState.label])
            link.setBeacons([NewMotionBeacon.uuid(pairingID: device.deviceID)])
            link.start()
            sendHandshakeHelloIfNeeded()
        } catch {
            IPhoneDebugLog.emit("reconnect_skip", ["reason": "load_fail"])
            latestAction = "Saved Mac could not be loaded; scan a new QR code"
        }
    }

    private func sendHandshakeHelloIfNeeded() {
        guard !handshakeHelloSent, authenticatedSession == nil,
              let client = pairingClient, link.state == .connected else { return }
        do {
            try sendHandshake(client.hello)
            handshakeHelloSent = true
            IPhoneDebugLog.emit("hello_sent", ["link": linkState.label])
            latestAction = awaitingMacName.map { "Waiting for \($0) to allow this iPhone" } ?? "Authenticating with Mac…"
            scheduleHandshakeHelloRetry()
        } catch {
            failPairing()
        }
    }

    private func scheduleHandshakeHelloRetry() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard authenticatedSession == nil, pairingClient != nil, pairingConfirmed,
                  link.state == .connected else { return }
            if let pairingToken, pairingToken.isExpired(at: Date()) {
                // The Mac's user never answered within the code's lifetime.
                abandonOneTimePairing()
                latestAction = "The pairing code expired; show a new one on the Mac"
                resumeReconnectIfNeeded()
                return
            }
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
        pingBurstRemaining = Self.pingBurstCount
        linkLatency = "Measuring…"
        latestAction = "Measuring link"
        for index in 0..<Self.pingBurstCount {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(index * 250))
                self?.sendOnePing(manual: true)
            }
        }
    }

    /// One ping every couple of seconds, so the round trip is already known
    /// when the user thinks to ask.  It stands aside for a manual burst rather
    /// than feeding it a pong the burst did not send for.
    private func sendAutomaticPing() {
        guard pingBurstRemaining == 0 else { return }
        sendOnePing(manual: false)
    }

    private func sendOnePing(manual: Bool) {
        guard isControllable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        expireOutstandingPings(now: now)
        pingSentAt.append(now)
        guard inputUplink.send(.ping(PingPayload())) else {
            pingSentAt.removeLast()
            PhoneLatency.roundTrip.recordRefusal()
            if manual { latestAction = "Ping failed" }
            return
        }
        if manual { IPhoneDebugLog.emit("ping_sent", ["link": linkState.label]) }
    }

    /// Sends no pong can still belong to.  Without this one lost pong pairs
    /// every later pong with an older send, and the round trip reads long for
    /// as long as the link stays up.
    private func expireOutstandingPings(now: TimeInterval) {
        var abandoned = 0
        while let oldest = pingSentAt.first, now - oldest > Self.pingTimeout {
            pingSentAt.removeFirst()
            abandoned += 1
        }
        if pingSentAt.count > Self.maxOutstandingPings {
            abandoned += pingSentAt.count - Self.maxOutstandingPings
            pingSentAt.removeFirst(pingSentAt.count - Self.maxOutstandingPings)
        }
        for _ in 0..<abandoned { PhoneLatency.roundTrip.recordRefusal() }
    }

    private func recordPong() {
        let now = ProcessInfo.processInfo.systemUptime
        expireOutstandingPings(now: now)
        guard !pingSentAt.isEmpty else { return }
        let sent = pingSentAt.removeFirst()
        PhoneLatency.roundTrip.record(seconds: now - sent)
        guard pingBurstRemaining > 0 else { return }
        pingBurstRemaining -= 1
        let roundTrip = (now - sent) * 1_000
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
        latestAction = "Pong from Mac"
        IPhoneDebugLog.emit("ping_rtt", ["ms": String(format: "%.1f", roundTrip)])
    }

    /// The automatic ping and the summary line run only while a connected link
    /// is in front of the user: a phone in a pocket measures nothing.
    private func syncTelemetry() {
        guard isForeground, linkState == .connected else {
            telemetryTimers.forEach { $0.invalidate() }
            telemetryTimers.removeAll()
            return
        }
        guard telemetryTimers.isEmpty else { return }
        telemetryTimers = [
            repeatingTimer(every: Self.autoPingInterval) { $0.sendAutomaticPing() },
            repeatingTimer(every: Self.latencySummaryInterval) { PhoneLatency.emitSummary(link: $0.linkState.label) }
        ]
    }

    private func repeatingTimer(
        every interval: TimeInterval,
        tick: @escaping @Sendable @MainActor (NewMotionFeatureModel) -> Void
    ) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            let stillOwned = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                tick(self)
                return true
            }
            // The run loop holds a repeating timer even when nothing else
            // does, so an owner that went away has to stop it from here.
            if !stillOwned { timer.invalidate() }
        }
    }

    private func handleMessage(channel: LinkChannel, message: Data) {
        switch channel {
        case .data:
            handleApplicationMessage(message)
        case .control:
            guard pairingClient != nil, authenticatedSession == nil else { return }
            if message.starts(with: PairingServerDecline.magic) {
                handleDecline(message)
                return
            }
            do {
                try acceptServerHello(message)
            } catch {
                failPairing()
            }
        }
    }

    private func handleDecline(_ message: Data) {
        guard let pairingToken,
              (try? PairingServerDecline.decode(message))?.pairingID == pairingToken.pairingID else {
            failPairing()
            return
        }
        IPhoneDebugLog.emit("pairing_declined", ["link": linkState.label])
        abandonOneTimePairing()
        latestAction = "\(pairingToken.macDisplayName) did not allow this iPhone"
        resumeReconnectIfNeeded()
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
        awaitingMacName = nil
        isPaired = true
        reconnectFailures = 0
        _ = lifecycle.handle(.trustAdded)
        latestAction = "Paired with \(displayName)"
        IPhoneDebugLog.emit("paired", ["link": linkState.label])
        do {
            let summary = try pairingCoordinator.rememberPairedMac(
                deviceID: deviceID,
                displayName: displayName,
                peerIdentityPublicKey: result.result.peerIdentityPublicKey
            )
            trustedPeer = summary
            selectedMacID = summary.deviceID
            refreshTrustedMacs()
            IPhoneDebugLog.emit("trust_save", ["ok": "yes", "count": "\(trustedMacs.count)"])
        } catch {
            IPhoneDebugLog.emit("trust_save", ["ok": "no"])
            latestAction = "Paired, but this phone could not save the Mac"
        }
    }

    private func handleApplicationMessage(_ message: Data) {
        guard let session = authenticatedSession else { return }
        do {
            let envelope = try session.unwrapApplication(message)
            switch envelope.payload {
            case .pong:
                recordPong()
            case let .vocabulary(value):
                // The Mac walks its own screen and sends what it found. It
                // arrives between presses, so a press never waits for it.
                macVocabulary = value.phrases
                refreshVoiceBoost()
                IPhoneDebugLog.emit("vocabulary", ["n": "\(value.phrases.count)"])
            default:
                break
            }
        } catch {
            latestAction = "Link check failed"
        }
    }

    private func sendHandshake(_ payload: Data) throws {
        guard link.send(payload, on: .control, delivery: .reliable) == .sent else {
            throw PairingError.invalidHandshake
        }
    }

    private func failPairing() {
        let qrInProgress = pairingToken != nil
        let hadTrust = pairingCoordinator?.trustedDevices.isEmpty == false
        IPhoneDebugLog.emit("pairing_fail", [
            "oneTime": qrInProgress ? "yes" : "no",
            "trust": hadTrust ? "yes" : "no",
            "link": linkState.label
        ])
        pairingClient = nil
        pairingToken = nil
        authenticatedSession = nil
        awaitingMacName = nil
        isPaired = false
        handshakeHelloSent = false
        if qrInProgress {
            pairingConfirmed = false
            link.stop()
            latestAction = "Pairing failed; scan a new Mac QR code"
            // A scan that failed is no reason to give up the Mac this phone
            // already trusts. Without this the fallback waits for the next
            // scene change, and the phone sits dark until the app is reopened.
            resumeReconnectIfNeeded()
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
        link.stop()
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
        let travel = CursorDelta(x: delta.x, y: delta.y)
        if oneFingerScrolling {
            airScrollMomentum.track(travel: travel.y, at: ProcessInfo.processInfo.systemUptime)
            cursorMixer.handleScrollTravel(travel)
        } else {
            cursorMixer.handleTravel(travel)
        }
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
        airScrollMomentum.strength = value
        UserDefaults.standard.set(value, forKey: "scrollMomentum")
    }

    func handleRemoteInputEvents(_ events: [RemoteInputEvent]) {
        guard isControllable else { return }
        cursorMixer.handle(events)
    }

    /// The on-device route's one delivery point.  A finished sentence crosses
    /// four places it can be dropped without a word, so this one says which;
    /// counts only, never the text.
    private func typeTranscribedText(_ text: String) {
        voicePreview = ""
        guard isControllable else {
            IPhoneDebugLog.emit("ondevice_drop", ["why": "notReady", "link": linkState.label])
            latestAction = "Pair before typing"
            return
        }
        var pieces = SpokenTextChunker.split(text)
        guard !pieces.isEmpty else {
            IPhoneDebugLog.emit("ondevice_drop", ["why": "empty"])
            return
        }
        // The recogniser hands back a trimmed sentence, so without this the
        // next utterance would butt straight against this one.
        pieces[pieces.count - 1] += " "
        for piece in pieces {
            guard let payload = try? SpokenTextPayload(text: piece),
                  inputUplink.send(.spokenText(payload)) else {
                IPhoneDebugLog.emit("ondevice_drop", ["why": "wire", "chars": "\(text.count)"])
                latestAction = "Voice text failed"
                return
            }
        }
        IPhoneDebugLog.emit("ondevice_typed", [
            "chars": "\(text.count)",
            "parts": "\(pieces.count)"
        ])
        latestAction = "Typing"
    }

    /// Characters are forwarded as they are typed and never stored or logged.
    func typeText(_ text: String) {
        guard isControllable else {
            latestAction = "Pair before typing"
            return
        }
        keyboard.type(text)
    }

    /// The walk holds its modifier open on the Mac between begin and commit,
    /// so a dropped phase would strand it.  These go reliable like every other
    /// input message, and the Mac releases the modifier on disconnect
    /// regardless.
    func sendTabWalk(_ phase: TabWalkPhase, holding modifier: HeldModifier) {
        guard isControllable else {
            latestAction = "Pair before walking tabs"
            return
        }
        guard inputUplink.send(.tabWalk(TabWalkPayload(phase: phase, modifier: modifier))) else {
            latestAction = "Tab walk send failed"
            return
        }
        latestAction = "Tab walk \(modifier) \(phase)"
        IPhoneDebugLog.emit("tab_walk", ["modifier": "\(modifier)", "phase": "\(phase)"])
    }

    func sendHotkey(_ hotkey: RemoteHotkey) {
        guard isControllable else {
            latestAction = "Pair before using hotkeys"
            return
        }
        keyboard.send(hotkey)
    }

    /// One notch of a held delete key.  It goes out beside the hotkeys rather
    /// than through them, because the Mac has to keep the characters a notch
    /// removed in order to put them back.
    func sendDeleteScrub(_ phase: DeleteScrubPhase, granularity: DeleteScrubGranularity) {
        guard isControllable else {
            latestAction = "Pair before erasing"
            return
        }
        let payload = DeleteScrubPayload(phase: phase, granularity: granularity)
        guard inputUplink.send(.deleteScrub(payload)) else {
            latestAction = "Erase send failed"
            return
        }
        // Deliberately quiet on the notches themselves.  Narrating each one
        // republishes the model, which rebuilds the whole trackpad screen
        // under the finger that is still sliding.
        switch phase {
        case .begin: latestAction = "Erasing"
        case .end: latestAction = "Erased"
        case .delete, .restore: break
        }
    }

    private func sendKeyboardOutput(_ output: KeyboardOutput) {
        guard let payload = try? SharedKeyboardProtocolAdapter.payload(for: output) else {
            IPhoneDebugLog.emit("key_send_failed", ["at": "encode"])
            latestAction = "Keyboard send failed"
            return
        }
        guard inputUplink.send(payload) else {
            IPhoneDebugLog.emit("key_send_failed", ["at": "wire"])
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
        case .dragBegan:
            label = "Drag began"
            Haptics.play(.gestureBegan)
        case .dragEnded:
            label = "Drag ended"
            Haptics.play(.gestureEnded)
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

/// The words the recogniser should lean towards.  Written on the main actor
/// and read on the voice queue, so both go through the lock.
private final class VoiceBoostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boost: [String] = []

    var words: [String] {
        lock.lock()
        defer { lock.unlock() }
        return boost
    }

    func update(_ words: [String]) {
        lock.lock()
        boost = words
        lock.unlock()
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
    let scrollSensitivity: Double
    let momentumStrength: Double
    /// A drag holds a real mouse button down on the Mac, so it has to end when
    /// the app stops being the thing in front.
    let isActive: Bool
    let onOneFingerScroll: (Bool) -> Void
    let onOutputs: ([RemoteInputEvent]) -> Void

    func makeUIView(context: Context) -> TrackpadTouchCaptureView {
        let view = TrackpadTouchCaptureView(frame: .zero)
        view.onOutputs = onOutputs
        view.onOneFingerScrollChanged = onOneFingerScroll
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TrackpadTouchCaptureView, context: Context) {
        uiView.onOutputs = onOutputs
        uiView.onOneFingerScrollChanged = onOneFingerScroll
        apply(to: uiView)
    }

    private func apply(to view: TrackpadTouchCaptureView) {
        view.engine.setSensitivity(
            pointerX: pointerSensitivityX,
            pointerY: pointerSensitivityY,
            scroll: scrollSensitivity
        )
        view.momentumStrength = momentumStrength
        view.setActive(isActive)
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
        case .selectAll: return "⌘A"
        case .tab: return "tab"
        case .arrowUp: return "up"
        case .arrowDown: return "down"
        case .arrowLeft: return "left"
        case .arrowRight: return "right"
        case .nextWindow: return "⌘`"
        case .newItem: return "⌘N"
        case .newTab: return "⌘T"
        case .closeWindow: return "⌘W"
        case .selectLeft: return "⇧←"
        case .selectRight: return "⇧→"
        case .selectUp: return "⇧↑"
        case .selectDown: return "⇧↓"
        }
    }

    var spokenName: String {
        switch self {
        case .escape: return "Escape"
        case .return: return "Return"
        case .deleteBackward: return "Backspace"
        case .deleteWordBackward: return "Backspace word"
        case .deleteLineBackward: return "Backspace line"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select all"
        case .nextWindow: return "Next window"
        case .newItem: return "New"
        case .newTab: return "New tab"
        case .closeWindow: return "Close window"
        default: return buttonTitle
        }
    }
}

/// Hold a modifier open on the Mac, slide to step along whatever that modifier
/// walks, lift to pick.  Command walks apps, Control walks the front app's
/// tabs.  A plain tap is the ordinary one-step flip, because begin already
/// takes that step.
struct TabWalkButton: View {
    /// Travel per app.  Half a thumb's width: far enough that a wobble while
    /// holding does not step, close enough to cross a full switcher in one
    /// slide.
    static let stepWidth: Double = 22

    let title: String
    let modifier: HeldModifier
    let spokenName: String
    let send: (TabWalkPhase, HeldModifier) -> Void
    @State private var isHeld = false
    @State private var steps = 0

    var body: some View {
        Text(title)
            .heldKeyStyle(isHeld: isHeld)
            .holdSlide("tab_walk", spokenName: spokenName, onPhase: handle)
    }

    private func handle(_ phase: HoldSlidePhase) {
        switch phase {
        case .began:
            guard !isHeld else { return }
            isHeld = true
            steps = 0
            Haptics.play(.press)
            step(.begin)
        case let .moved(translationX, _):
            guard isHeld else { return }
            step(to: Int((translationX / Self.stepWidth).rounded(.towardZero)))
        case .ended:
            finish(.commit)
        case .cancelled:
            finish(.cancel)
        }
    }

    private func step(to target: Int) {
        guard steps != target else { return }
        while steps < target {
            steps += 1
            step(.next)
        }
        while steps > target {
            steps -= 1
            step(.previous)
        }
        Haptics.play(.step)
    }

    private func step(_ phase: TabWalkPhase) {
        send(phase, modifier)
    }

    private func finish(_ phase: TabWalkPhase) {
        guard isHeld else { return }
        isHeld = false
        steps = 0
        Haptics.play(.release)
        step(phase)
    }
}

struct NewMotionControlView: View {
    @StateObject private var model = NewMotionFeatureModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RemoteControlScreen(model: model)
        // Into the bottom safe area, so the targets sit in the true corners of
        // the screen.
        .overlay {
            PushToTalkDragZones(
                controller: model.pushToTalk,
                sides: model.layoutMode.pushToTalkZoneSides(mirrored: model.mirrorHorizontalLayout)
            )
                .ignoresSafeArea()
        }
        // Above the keys rather than over the trackpad, so the words being
        // heard are readable without covering anything the thumb is using.
        .overlay(alignment: .top) { VoicePreviewBanner(text: model.voicePreview) }
        .onAppear { model.scenePhaseChanged(.active) }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            model.logPairingDiagnostics()
        }
    }
}

private struct RemoteControlScreen: View {
    @ObservedObject var model: NewMotionFeatureModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isKeyboardShowing = false
    @State private var isSettingsShowing = false

    var body: some View {
        layout
            // An invisible responder, so where it sits does not matter.
            .overlay(alignment: .bottom) {
                RemoteKeyboardSurface(
                    isShowing: $isKeyboardShowing,
                    onText: { model.typeText($0) },
                    onHotkey: { model.sendHotkey($0) }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .sheet(isPresented: $isSettingsShowing) {
                RemoteSettingsSheet(model: model)
            }
            .onAppear {
                Haptics.prepare()
                model.setTrackpadVisible(true)
                InterfaceOrientationLock.apply(model.layoutMode.orientations)
            }
            // The sheet covers the trackpad without the screen going away, so
            // this is the moment the trackpad stops being the thing in front.
            .onChange(of: isSettingsShowing) { _, showing in
                if showing { isKeyboardShowing = false }
                model.setTrackpadVisible(!showing)
            }
    }

    /// Adding a layout is a file of its own and a case here; the pieces it
    /// arranges are the same ones every other layout gets.
    @ViewBuilder
    private var layout: some View {
        switch model.layoutMode {
        case .vertical:
            VerticalRemoteLayout(pushToTalk: model.pushToTalk, keys: keys) {
                trackpad
            } controls: {
                trackpadControls
            }
        case .controller:
            ControllerRemoteLayout(
                pushToTalk: model.pushToTalk,
                keys: keys,
                mirrored: model.mirrorHorizontalLayout
            ) {
                trackpad
            } controls: {
                trackpadControls
            }
        }
    }

    private var keys: RemoteKeys {
        RemoteKeys(
            send: { model.sendHotkey($0) },
            walk: { model.sendTabWalk($0, holding: $1) },
            scrub: { model.sendDeleteScrub($0, granularity: $1) }
        )
    }

    private var trackpad: some View {
        TrackpadSurface(
            pointerSensitivityX: model.trackpadSensitivityX,
            pointerSensitivityY: model.trackpadSensitivityY,
            scrollSensitivity: model.trackpadScrollSensitivity,
            momentumStrength: model.scrollMomentum,
            isActive: scenePhase == .active,
            onOneFingerScroll: { scrolling in
                model.setOneFingerScrolling(scrolling)
                Haptics.play(scrolling ? .gestureBegan : .gestureEnded)
            }
        ) { outputs in
            model.handleRemoteInputEvents(outputs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            Text("Tap, two-finger tap, double tap and slide")
                .font(.caption)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
    }

    /// The buttons that float over the trackpad's corners rather than taking
    /// slots in the pad, so they cost no height.  Handed to the layout apart
    /// from the surface, because a layout may run the surface under the safe
    /// area while these have to stay clear of it.
    private var trackpadControls: some View {
        ZStack {
            SettingsButton { isSettingsShowing = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: RemoteKeyMetrics.spacing) {
                LayoutToggleButton(mode: model.layoutMode) {
                    model.setLayoutMode(model.layoutMode.next)
                }
                KeyboardToggleButton(isShowing: $isKeyboardShowing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // Centred in the same row, where either thumb can reach it without
            // covering the keyboard button.
            ArrowPadKey(send: { model.sendHotkey($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(8)
    }
}

/// Opens the settings sheet.  A corner of the trackpad rather than a tab bar,
/// which cost a whole row for one destination.
private struct SettingsButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: Haptics.tap(open)) {
            Image(systemName: "gearshape")
                .font(.title3)
                .frame(width: RemoteKeyMetrics.keyWidth, height: RemoteKeyMetrics.keyHeight)
                .contentShape(Rectangle())
        }
        .background(Color(.tertiarySystemFill))
        .foregroundStyle(Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Settings")
    }
}

/// Flips between the upright and sideways layouts, and turns the screen with
/// them.
private struct LayoutToggleButton: View {
    let mode: RemoteLayoutMode
    let toggle: () -> Void

    var body: some View {
        Button(action: Haptics.tap(toggle)) {
            Image(systemName: mode.toggleSymbol)
                .font(.title3)
                .frame(width: RemoteKeyMetrics.keyWidth, height: RemoteKeyMetrics.keyHeight)
                .contentShape(Rectangle())
        }
        .background(Color(.tertiarySystemFill))
        .foregroundStyle(Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(mode.toggleLabel)
    }
}

/// Opens and closes the system keyboard; the trackpad under it stays live
/// either way.
private struct KeyboardToggleButton: View {
    @Binding var isShowing: Bool

    var body: some View {
        Button(action: Haptics.tap { isShowing.toggle() }) {
            Image(systemName: isShowing ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.title3)
                .frame(width: RemoteKeyMetrics.keyWidth, height: RemoteKeyMetrics.keyHeight)
                .contentShape(Rectangle())
        }
        .background(isShowing ? Color.accentColor : Color(.tertiarySystemFill))
        .foregroundStyle(isShowing ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(isShowing ? "Hide keyboard" : "Show keyboard")
    }
}

private struct RemoteSettingsSheet: View {
    @ObservedObject var model: NewMotionFeatureModel
#if DEBUG
    @ObservedObject private var debugLog = IPhoneDebugLog.shared
#endif
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing") {
                    if let name = model.awaitingMacName {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Waiting for \(name)")
                                .font(.headline)
                            Text("Click Allow on the Mac to finish pairing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Cancel", action: Haptics.tap { model.cancelPairing() })
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else if model.isPairingVisible {
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

                        Button("Cancel scanner", action: Haptics.tap { model.cancelPairing() })
                    } else {
                        Button("Scan Mac QR Code", action: Haptics.tap { model.startPairing() })
                        Button(
                            model.isPaired ? "Ping Mac" : "Ping Mac (waiting)",
                            action: Haptics.tap { model.sendPing() }
                        )
                    }

                    LabeledContent("Link", value: model.linkStatus)
                    LabeledContent("Link round trip", value: model.linkLatency)
                    if model.trustedMacs.count > 1 {
                        Picker("Mac", selection: Binding(
                            get: { model.selectedMac?.deviceID },
                            set: { if let id = $0 { model.selectMac(id) } }
                        )) {
                            ForEach(model.trustedMacs, id: \.deviceID) { mac in
                                Text(mac.displayName).tag(Optional(mac.deviceID))
                            }
                        }
                    } else if let trustedMacName = model.trustedMacName {
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

                Section("Layout") {
                    Toggle(
                        "Mirror horizontal mode",
                        isOn: Binding(
                            get: { model.mirrorHorizontalLayout },
                            set: { model.setMirrorHorizontalLayout($0) }
                        )
                    )
                    Text("Trackpad on the left, keys on the right, for the left hand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section {
                    LabeledContent("Status", value: model.onDeviceVoiceStatus)
                        .font(.caption)
                    TextField(
                        "Ollama, Xcode, Testaflight",
                        text: Binding(
                            get: { model.voiceBoostWords },
                            set: { model.setVoiceBoostWords($0) }
                        ),
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
                    Text("Names to listen harder for, separated by commas. Names on the Mac's screen are added to these on their own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Voice typing")
                } footer: {
                    Text("Hold to talk and your words are turned into text here on the iPhone, then typed on the Mac. The sound itself never leaves this phone.")
                }

#if DEBUG
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
#endif
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done", action: Haptics.tap { dismiss() })
            }
        }
    }
}

@main
struct NewMotionApp: App {
    /// The delegate reports the orientation the layout mode asks for.
    @UIApplicationDelegateAdaptor(NewMotionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            NewMotionControlView()
        }
    }
}
#else
@main
struct NewMotionApp: App {
    var body: some Scene {
        WindowGroup { Text("NewMotion requires iOS") }
    }
}
#endif

/// The words heard so far, while the finger is still down.  It is the only
/// place a transcript is ever shown, and it goes as soon as the sentence is
/// sent; nothing here is logged or stored.
private struct VoicePreviewBanner: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}
