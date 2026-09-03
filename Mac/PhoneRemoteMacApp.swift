import SwiftUI
import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

#if os(macOS)
import AppKit

private extension BLECentralLifecycleState {
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .waitingForBluetooth: return "Waiting for Bluetooth"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .discovering: return "Discovering service"
        case .subscribing: return "Subscribing"
        case .ready: return "Ready"
        case .disconnected: return "Disconnected"
        case .stopped: return "Stopped"
        }
    }
}

/// The menu-bar surface owns no independent safety state. It talks to the
/// same lifecycle coordinator that the eventual BLE session will use, so a
/// local pause or an Accessibility revocation follows the normal release-all
/// path even before a phone is paired.
@MainActor
final class MacRemoteAppModel: ObservableObject {
    private static let trustedDeviceService = "com.example.phoneremote.macos.trusted-devices"

    private let injector: SafeInputInjector
    private let lifecycle: MacLifecycleCoordinator
    private let central: MacBLECentralTransport
    private let pairingOffer: MacPairingOfferController
    private let pairingCoordinator: MacPairingCoordinator?
    private let qrRenderer: MacPairingQRCodeRenderer
    private var inboundReassembler: BLEReassembler?
    private var controlReassembler: BLEReassembler?
    private var pairingServer: PairingHandshakeServer?
    private var pairingID: UUID?
    private var pairingDeviceName: String?
    private var authenticatedSession: PairingSession?
    private var nextHandshakeMessageID: UInt32 = 1
    private var nextApplicationSequence: UInt64 = 1

    @Published private(set) var status: RemoteMenuBarStatus = .disconnected { didSet { publishDebugState() } }
    @Published private(set) var accessibility: AccessibilityState = .unknown { didSet { publishDebugState() } }
    @Published private(set) var bluetoothState: BLECentralLifecycleState = .idle { didSet { publishDebugState() } }
    @Published private(set) var pairingState: MacPairingOfferState = .idle { didSet { publishDebugState() } }
    @Published private(set) var pairingProgress: MacPairingProgress = .idle { didSet { publishDebugState() } }
    @Published private(set) var pairedDevices: [TrustedDeviceSummary] = [] { didSet { publishDebugState() } }
    @Published private(set) var pairingError: String? { didSet { publishDebugState() } }
    @Published private(set) var pairingQRImage: NSImage? { didSet { publishDebugState() } }
    @Published private(set) var pairingExpiry: Date? { didSet { publishDebugState() } }
    @Published private(set) var lastApplicationMessage: String? { didSet { publishDebugState() } }
    @Published private(set) var lastPairingFailure: String? { didSet { publishDebugState() } }
    @Published private(set) var voice = VoicePTTState() { didSet { publishDebugState() } }
    private let voiceCoordinator: VoicePTTCoordinator
    private let speechServer = NemotronServer()
    private let debugSnapshotBox = MacDebugSnapshotBox()
    private var debugServer: MacDebugHTTPServer?

    init() {
        let trust = SystemAccessibilityTrust()
        let sink = CGEventInputSink(trust: trust)
        let injector = SafeInputInjector(sink: sink, accessibility: trust)
        let central = MacBLECentralTransport(adapter: CoreBluetoothCentralManagerAdapter())
        let pairingOffer = MacPairingOfferController()
        let pairingCoordinator = try? MacPairingCoordinator(
            store: KeychainTrustedDeviceStore(service: Self.trustedDeviceService),
            offerController: pairingOffer
        )
        self.injector = injector
        self.lifecycle = MacLifecycleCoordinator(injector: injector)
        let voiceCoordinator = VoicePTTCoordinator(sessions: speechServer, insertionSink: injector)
        self.voiceCoordinator = voiceCoordinator
        self.central = central
        self.pairingOffer = pairingOffer
        self.pairingCoordinator = pairingCoordinator
        self.qrRenderer = MacPairingQRCodeRenderer()
        self.pairedDevices = pairingCoordinator?.trustedDevices ?? []
        let reassembledLimit = BLEFramingLimits.maximumEnvelopeBytes + BLEFramingLimits.headerBytes
        self.inboundReassembler = try? BLEReassembler(maximumValueLength: reassembledLimit)
        self.controlReassembler = try? BLEReassembler(maximumValueLength: reassembledLimit)

        central.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.handleCentralState(state) }
        }
        central.onFrameReceived = { [weak self] channel, data in
            Task { @MainActor [weak self] in self?.handleIncomingFrame(channel: channel, data: data) }
        }
        central.onTransportError = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTransportError() }
        }
        handleCentralState(central.state)
        pairingOffer.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.pairingState = state
                guard let self else { return }
                if case .active = state {
                    self.pairingProgress = .waitingForConfirmation
                    return
                }
                self.pairingQRImage = nil
                self.pairingExpiry = nil
                if self.authenticatedSession == nil {
                    self.restoreProgressAfterOfferChange()
                }
            }
        }
        pairingOffer.onOfferReady = { [weak self] text, expiry in
            guard let self else { return }
            do {
                let image = try self.qrRenderer.render(text: text)
                let rendered = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
                self.pairingQRImage = rendered
                self.pairingExpiry = expiry
            } catch {
                self.pairingQRImage = nil
                self.pairingExpiry = nil
            }
        }

        voiceCoordinator.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let phaseChanged = state.phase != self.voice.phase
                self.voice = state
                guard phaseChanged else { return }
                switch state.phase {
                case .listening:
                    self.lastApplicationMessage = "Listening"
                case .transcribing:
                    self.lastApplicationMessage = "Transcribing"
                case .typed:
                    self.lastApplicationMessage = "Typed spoken text"
                case .failed:
                    self.lastApplicationMessage = "Voice typing failed"
                case .idle:
                    break
                }
            }
        }
        speechServer.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [speechServer] _ in speechServer.stop() }

        _ = lifecycle.handle(.startup)
        refreshAccessibility(prompt: false)
        central.start()
        publishDebugState()
        startDebugServerIfNeeded()
    }

    var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    func togglePause() {
        _ = lifecycle.handle(isPaused ? .userResume : .userPause)
        updateStatus()
    }

    func refreshAccessibility(prompt: Bool) {
        if prompt { openAccessibilitySettings() }
        accessibility = injector.refreshAccessibility(prompt: prompt)
        _ = lifecycle.handle(.accessibilityChanged(accessibility))
        updateStatus()
    }

    private func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    func issuePairingOffer() {
        guard let pairingCoordinator else {
            pairingError = "Pairing storage is unavailable on this Mac"
            pairingProgress = .failed
            return
        }
        do {
            pairingError = nil
            _ = try pairingCoordinator.issueOffer(displayName: Host.current().localizedName ?? "Mac")
            pairingProgress = .waitingForConfirmation
        } catch {
            pairingState = .idle
            pairingQRImage = nil
            pairingExpiry = nil
            pairingError = "Could not create a pairing offer"
            pairingProgress = .failed
        }
    }

    func cancelPairingOffer() {
        pairingOffer.cancel()
    }

    func tickPairingOffer() {
        pairingOffer.tick()
    }

    private func updateStatus() {
        status = lifecycle.status()
    }

    private func handleCentralState(_ state: BLECentralLifecycleState) {
        bluetoothState = state
        switch state {
        case .idle:
            if authenticatedSession == nil { pairingProgress = .idle }
        case .waitingForBluetooth:
            pairingProgress = .waitingForBluetooth
        case .scanning:
            if authenticatedSession != nil {
                clearHandshakeState()
                _ = lifecycle.handle(.disconnected)
                updateStatus()
            }
            if authenticatedSession == nil {
                if case .active = pairingOffer.state {
                    break
                }
                pairingProgress = .scanning
            }
        case .connecting:
            pairingProgress = .connecting(deviceName: visiblePeripheralName)
        case .discovering, .subscribing:
            pairingProgress = .connected(deviceName: visiblePeripheralName)
        case .ready:
            if authenticatedSession != nil {
                pairingProgress = .paired(deviceName: pairingDeviceName ?? visiblePeripheralName)
            } else {
                pairingProgress = .connected(deviceName: visiblePeripheralName)
            }
        case .disconnected:
            clearHandshakeState()
            _ = lifecycle.handle(.disconnected)
            updateStatus()
            pairingProgress = .disconnected
        case .stopped:
            clearHandshakeState()
            _ = lifecycle.handle(.disconnected)
            updateStatus()
            pairingProgress = .disconnected
        }
    }

    private func restoreProgressAfterOfferChange() {
        switch central.state {
        case .waitingForBluetooth: pairingProgress = .waitingForBluetooth
        case .scanning: pairingProgress = .scanning
        case .connecting: pairingProgress = .connecting(deviceName: visiblePeripheralName)
        case .discovering, .subscribing: pairingProgress = .connected(deviceName: visiblePeripheralName)
        case .ready: pairingProgress = .connected(deviceName: visiblePeripheralName)
        case .disconnected, .stopped: pairingProgress = .disconnected
        case .idle: pairingProgress = .idle
        }
    }

    private var visiblePeripheralName: String {
        let name = central.visiblePeripheral?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name : nil) ?? "iPhone"
    }

    private func handleIncomingFrame(channel: BLETransportChannel, data: Data) {
        if channel == .data {
            if authenticatedSession != nil {
                handleApplicationFrame(channel: channel, data: data)
            }
            return
        }
        // Hello can arrive in the same turn as the last subscribe callback,
        // before this state machine has moved to `.ready`. A later hello must
        // also be accepted if the Mac already thought it was paired; otherwise
        // the phone retries forever and ping/trackpad stay dead.
        guard channel == .control, let reassembler = controlReassembler else { return }
        switch central.state {
        case .subscribing, .ready:
            break
        case .idle, .waitingForBluetooth, .scanning, .connecting, .discovering, .disconnected, .stopped:
            return
        }
        do {
            switch try reassembler.append(data) {
            case .incomplete, .duplicate:
                return
            case let .complete(payload, kind, _, _):
                guard kind == .control else { throw PairingError.invalidHandshake }
                if payload.starts(with: PairingClientHello.magic) {
                    pairingServer = nil
                    controlReassembler?.reset()
                    try beginHandshake(payload: payload)
                } else if payload.starts(with: PairingClientFinish.magic) {
                    guard let pairingServer else { throw PairingError.invalidHandshake }
                    try finishHandshake(server: pairingServer, payload: payload)
                } else if authenticatedSession == nil {
                    throw PairingError.invalidHandshake
                }
            }
        } catch {
            failPairing(error)
        }
    }

    private func beginHandshake(payload: Data) throws {
        guard let pairingCoordinator else { throw PairingError.tokenNotActive }
        let hello = try PairingClientHello.decode(payload)
        let server = try pairingCoordinator.makeHandshakeServer(pairingID: hello.pairingID)
        pairingID = hello.pairingID
        pairingDeviceName = visiblePeripheralName
        pairingServer = server
        if authenticatedSession == nil {
            pairingProgress = .authenticating(deviceName: visiblePeripheralName)
        }
        let response = try server.accept(clientHelloData: payload)
        try sendHandshake(response.response)
    }

    private func finishHandshake(server: PairingHandshakeServer, payload: Data) throws {
        guard let pairingCoordinator, let pairingID else { throw PairingError.invalidHandshake }
        let result = try server.accept(clientFinishData: payload)
        let displayName = pairingDeviceName ?? visiblePeripheralName
        _ = try pairingCoordinator.rememberPairedPhone(
            deviceID: pairingID,
            displayName: displayName,
            peerIdentityPublicKey: result.peerIdentityPublicKey
        )
        pairedDevices = pairingCoordinator.trustedDevices
        authenticatedSession = result.session
        pairingServer = nil
        pairingError = nil
        lastPairingFailure = nil
        pairingProgress = .paired(deviceName: displayName)
        inboundReassembler?.reset()
        controlReassembler?.reset()
        nextApplicationSequence = 1
        lastApplicationMessage = nil
        _ = lifecycle.handle(.authenticated)
        updateStatus()
    }

    private func sendHandshake(_ payload: Data) throws {
        let messageID = nextHandshakeMessageID
        nextHandshakeMessageID = messageID == UInt32.max ? 1 : messageID &+ 1
        let frames = try BLEFragmenter().fragment(
            payload: payload,
            kind: .control,
            reliable: true,
            messageID: messageID,
            maximumValueLength: max(BLEFramingLimits.minimumValueLength, central.maximumWriteValueLength)
        )
        for frame in frames {
            guard central.send(frame, on: .control, reliable: true) else {
                throw PairingError.invalidHandshake
            }
        }
    }

    private func handleTransportError() {
        if authenticatedSession != nil {
            clearHandshakeState()
            _ = lifecycle.handle(.disconnected)
            updateStatus()
            pairingProgress = .disconnected
            return
        }
        if pairingServer != nil {
            failPairing()
            return
        }
        // The phone vanished before hello. Keep the QR offer and wait again.
        updateStatus()
        if case .active = pairingOffer.state {
            pairingProgress = .waitingForConfirmation
        }
    }

    private func failPairing(_ error: Error? = nil) {
        if authenticatedSession != nil {
            pairingServer = nil
            lastPairingFailure = Self.pairingFailureName(error)
            return
        }
        clearHandshakeState()
        _ = lifecycle.handle(.disconnected)
        updateStatus()
        lastPairingFailure = Self.pairingFailureName(error)
        pairingError = "Pairing failed. The phone will retry, or show a new QR code."
        pairingProgress = .failed
    }

    private static func pairingFailureName(_ error: Error?) -> String? {
        switch error {
        case let pairing as PairingError:
            return String(describing: pairing)
        case let framing as BLEFramingError:
            return String(describing: framing)
        case .some:
            return "handshake"
        case .none:
            return nil
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
                let decrypted = try session.decrypt(payload)
                if decrypted.messageType == MessageType.audioChunk.rawValue,
                   decrypted.plaintext.starts(with: VoiceStreamFrame.magic) {
                    voiceCoordinator.receive(try VoiceStreamFrame.decode(decrypted.plaintext))
                    return
                }
                let envelope = try ProtocolCodec.decode(Array(decrypted.plaintext))
                try dispatchApplication(envelope.payload)
            }
        } catch {
            lastApplicationMessage = "error"
        }
    }

    private func dispatchApplication(_ payload: MessagePayload) throws {
        switch payload {
        case .ping:
            try sendApplication(.pong(PongPayload()))
            lastApplicationMessage = "Pong sent"
        case .pong:
            lastApplicationMessage = "pong"
            return
        default:
            if let command = try? SharedInputProtocolAdapter.command(for: payload) {
                switch injector.submit(command) {
                case .applied:
                    lastApplicationMessage = String(describing: payload.messageType)
                case .denied:
                    lastApplicationMessage = "\(payload.messageType) blocked"
                case .failed:
                    lastApplicationMessage = "\(payload.messageType) failed"
                }
            } else {
                lastApplicationMessage = String(describing: payload.messageType)
            }
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
            maximumValueLength: max(BLEFramingLimits.minimumValueLength, central.maximumWriteValueLength)
        )
        for frame in frames {
            let reliable = envelope.messageType.deliveryClass == .reliable
            guard central.send(frame, on: .data, reliable: reliable) else {
                throw PairingError.invalidHandshake
            }
        }
    }

    private func clearHandshakeState() {
        pairingServer = nil
        pairingID = nil
        pairingDeviceName = nil
        authenticatedSession = nil
        lastApplicationMessage = nil
        inboundReassembler?.reset()
        controlReassembler?.reset()
        publishDebugState()
    }

    private func startDebugServerIfNeeded() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if NSClassFromString("XCTestCase") != nil { return }
        if ProcessInfo.processInfo.environment["PHONE_REMOTE_DEBUG_SERVER"] == "0" { return }
        let server = MacDebugHTTPServer(box: debugSnapshotBox)
        server.start()
        debugServer = server
    }

    private func publishDebugState() {
        debugSnapshotBox.update(makeDebugSnapshot())
    }

    private func makeDebugSnapshot() -> MacDebugSnapshot {
        let offer: String
        switch pairingState {
        case .idle: offer = "idle"
        case .active: offer = "active"
        case .cancelled: offer = "cancelled"
        case .expired: offer = "expired"
        }
        return MacDebugSnapshot(
            status: status.title,
            paused: isPaused,
            accessibility: accessibility.rawValue,
            bluetooth: bluetoothState.label,
            bluetoothKind: String(describing: bluetoothState),
            pairingProgress: pairingProgress.title,
            pairingProgressKind: pairingProgress.kind,
            authenticated: authenticatedSession != nil || pairingProgress.isAuthenticated,
            pairingOffer: offer,
            hasPairingQR: pairingQRImage != nil,
            pairingError: pairingError,
            lastPairingFailure: lastPairingFailure,
            visiblePeripheralName: visiblePeripheralName,
            lastApplicationMessage: lastApplicationMessage,
            audioPhase: voice.phase.rawValue,
            audioFrames: voice.health.receivedFrames,
            audioSamples: voice.health.receivedSamples,
            audioMissingChunks: voice.health.missingChunks,
            appPath: (Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath,
            pairedDevices: pairedDevices.map {
                MacDebugPairedDevice(displayName: $0.displayName, pairedAt: $0.pairedAt)
            }
        )
    }
}

struct MacRemoteStatusView: View {
    @ObservedObject var model: MacRemoteAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Phone Remote", systemImage: "cursorarrow.rays")
                .font(.headline)

            Text(model.status.title)
                .foregroundStyle(model.isPaused ? .orange : .secondary)

            LabeledContent("Accessibility", value: model.accessibility.rawValue)
                .font(.caption)
            Text((Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.accessibility != .granted {
                Text("Turn on this copy in System Settings, then tap Refresh Accessibility. Do not enable a /tmp or DerivedData build.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Bluetooth", value: model.bluetoothState.label)
                .font(.caption)
            Label(model.pairingProgress.title,
                  systemImage: model.pairingProgress.isAuthenticated ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(model.pairingProgress.isAuthenticated ? .green : .secondary)
            if let paired = model.pairedDevices.last {
                LabeledContent("Paired device", value: paired.displayName)
                    .font(.caption)
            }
            if let error = model.pairingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let probe = model.lastApplicationMessage {
                Text(probe)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.voice.phase != .idle {
                Text(model.voice.phase.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AudioHealthIndicatorView(health: model.voice.health)
            }
            if !model.voice.preview.isEmpty {
                Text(model.voice.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let final = model.voice.lastFinalText {
                Text(final)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(model.isPaused ? "Resume Remote Control" : "Pause Remote Control") {
                model.togglePause()
            }
            .keyboardShortcut(.defaultAction)

            Button("Refresh Accessibility") {
                model.refreshAccessibility(prompt: true)
            }

            Divider()
            if let image = model.pairingQRImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .accessibilityLabel("One-time pairing QR code")
                if let expiry = model.pairingExpiry {
                    Text("Pairing offer expires \(expiry.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel pairing offer") {
                    model.cancelPairingOffer()
                }
            } else {
                Button("Show one-time pairing QR") {
                    model.issuePairingOffer()
                }
            }

            Divider()
            if let paired = model.pairedDevices.last {
                Text("Saved \(paired.displayName). Open the phone app to reconnect. QR is only for a new phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pair a foreground iPhone to enable authenticated control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.tickPairingOffer()
        }
    }
}

@main
@MainActor
struct PhoneRemoteMacApp: App {
    @StateObject private var model = MacRemoteAppModel()

    var body: some Scene {
        MenuBarExtra("Phone Remote", systemImage: "cursorarrow.rays") {
            MacRemoteStatusView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
