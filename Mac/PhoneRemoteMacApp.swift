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

/// The macOS test bundle uses the real app as its test host, so every
/// `xcodebuild test` run launches this app. Bluetooth and the login Keychain
/// re-prompt on each unsigned rebuild, so the host stays inert under tests and
/// only wires the parts a unit test can exercise without the system asking the
/// user for anything.
enum MacHostRuntime {
    static let isInert: Bool = {
        if ProcessInfo.processInfo.environment["PHONE_REMOTE_INERT_HOST"] == "1" { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()
}

/// The menu-bar surface owns no independent safety state. It talks to the
/// same lifecycle coordinator that the eventual BLE session will use, so a
/// local pause or an Accessibility revocation follows the normal release-all
/// path even before a phone is paired.
@MainActor
final class MacRemoteAppModel: ObservableObject {
    private static let trustedDeviceService = "com.example.phoneremote.macos.trusted-devices"

    /// One beat is 250 ms, so the watchdog tolerates three lost in a row.  A
    /// held button that outlives the phone is a nuisance for this long; a
    /// selection dropped mid-drag by an impatient watchdog is worse.
    private static let heartbeatTimeout: TimeInterval = 1.0
    /// How often the watchdog is asked whether its window has passed.  It only
    /// decides the delay between the window closing and the release.
    private static let watchdogPollInterval: TimeInterval = 0.25

    private let injector: SafeInputInjector
    private let reliableInput: ReliableInputCoordinator
    /// Runs only while a phone is authenticated.  The watchdog itself stays
    /// disarmed until a heartbeat arrives, so a remote that holds nothing is
    /// never at risk of a release it did not need.
    private var watchdogTimer: Timer?
    private let pointerSmoothing: SmoothedTravelSink
    private let inputSink: CGEventInputSink
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
    private var authenticatedSession: PairingSession? {
        didSet {
            // A link can end in several places; it can only be authenticated
            // in one.  Following the session keeps the watchdog from having to
            // be started and stopped at each of them.
            if authenticatedSession == nil {
                stopWatchdog()
                // Releases anything still held.  This runs before the
                // lifecycle transition, so the button comes up immediately
                // rather than on the way through the unsafe state.
                reliableInput.disconnect()
            } else if oldValue == nil {
                startWatchdog()
            }
        }
    }
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
    @Published var smoothCursor = UserDefaults.standard.object(forKey: "pointerSmoothing") as? Bool ?? true
    @Published var smoothScroll = UserDefaults.standard.object(forKey: "scrollSmoothing") as? Bool ?? false
    @Published var screenVocabulary = UserDefaults.standard.object(forKey: "screenVocabulary") as? Bool ?? true
    @Published var smoothingMinimum = UserDefaults.standard.object(forKey: "smoothingMinimumDelta") as? Double
        ?? SmoothedTravelSink.defaultMinimumSmoothed
    /// Cursor traffic is counted, not narrated.  Publishing a label per packet
    /// rebuilt the whole debug snapshot and invalidated the SwiftUI surface
    /// sixty times a second, on the same actor that applies the packets.
    private var cursorEvents: UInt64 = 0
    private var lastCursorPublish: TimeInterval = 0
    private let voiceCoordinator: VoicePTTCoordinator
    private let speechServer: NemotronServer
    private let screenVocabularyReader: AXScreenVocabularyReader
    private let normalizer = S1MiniNormalizer()
    /// Experimental: only ever reached when the phone marks an utterance as an
    /// instruction, which its own setting gates.
    private let editor = QwenTranscriptEditor()
    private let debugSnapshotBox = MacDebugSnapshotBox()
    private var debugServer: MacDebugHTTPServer?
    private let focusedTextReader = AXFocusedTextReader()
    private let deleteScrub: DeleteScrubCoordinator

    init() {
        let vocabularyCache = VocabularyCache()
        let screenVocabularyReader = AXScreenVocabularyReader(
            isEnabled: UserDefaults.standard.object(forKey: "screenVocabulary") as? Bool ?? true,
            cache: vocabularyCache
        )
        self.screenVocabularyReader = screenVocabularyReader
        self.speechServer = NemotronServer(speechContext: screenVocabularyReader)
        let trust = SystemAccessibilityTrust()
        let sink = CGEventInputSink(trust: trust)
        self.inputSink = sink
        let smoothing = SmoothedTravelSink(
            wrapping: sink,
            cursor: UserDefaults.standard.object(forKey: "pointerSmoothing") as? Bool ?? true,
            scroll: UserDefaults.standard.object(forKey: "scrollSmoothing") as? Bool ?? false,
            minimumSmoothed: UserDefaults.standard.object(forKey: "smoothingMinimumDelta") as? Double
                ?? SmoothedTravelSink.defaultMinimumSmoothed
        )
        self.pointerSmoothing = smoothing
        let injector = SafeInputInjector(sink: smoothing, accessibility: trust)
        let inert = MacHostRuntime.isInert
        let adapter: MacCentralManagerAdapter = inert
            ? InertCentralManagerAdapter()
            : CoreBluetoothCentralManagerAdapter()
        let central = MacBLECentralTransport(adapter: adapter)
        let pairingOffer = MacPairingOfferController()
        let store: TrustedDeviceStore = inert
            ? InMemoryTrustedDeviceStore()
            : KeychainTrustedDeviceStore(service: Self.trustedDeviceService)
        let pairingCoordinator = try? MacPairingCoordinator(
            store: store,
            offerController: pairingOffer
        )
        self.injector = injector
        self.deleteScrub = DeleteScrubCoordinator(
            submitter: injector,
            focusedText: focusedTextReader
        )
        self.reliableInput = ReliableInputCoordinator(
            injector: injector,
            heartbeatTimeout: Self.heartbeatTimeout
        )
        self.lifecycle = MacLifecycleCoordinator(injector: injector)
        let voiceCoordinator = VoicePTTCoordinator(
            sessions: speechServer,
            insertionSink: injector,
            normalizer: normalizer,
            editor: editor,
            focusedText: focusedTextReader,
            vocabulary: vocabularyCache
        )
        self.voiceCoordinator = voiceCoordinator
        self.central = central
        self.pairingOffer = pairingOffer
        self.pairingCoordinator = pairingCoordinator
        self.qrRenderer = MacPairingQRCodeRenderer()
        self.pairedDevices = pairingCoordinator?.trustedDevices ?? []
        let reassembledLimit = BLEFramingLimits.maximumEnvelopeBytes + BLEFramingLimits.headerBytes
        self.inboundReassembler = try? BLEReassembler(maximumValueLength: reassembledLimit)
        self.controlReassembler = try? BLEReassembler(maximumValueLength: reassembledLimit)

        // Core Bluetooth already calls back on the main queue.  A `Task` hop
        // per frame queued every packet behind whatever the main actor was
        // doing, so a burst of cursor motion replayed slowly instead of
        // arriving.  The same fix was needed for the phone's motion sink.
        central.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.handleCentralState(state) }
        }
        central.onFrameReceived = { [weak self] channel, data in
            MainActor.assumeIsolated { self?.handleIncomingFrame(channel: channel, data: data) }
        }
        central.onTransportError = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTransportError() }
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
        if !inert {
            speechServer.start()
            normalizer.warmUp()
            screenVocabularyReader.warmUp()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [speechServer] _ in speechServer.stop() }

        _ = lifecycle.handle(.startup)
        refreshAccessibility(prompt: false)
        if !inert { central.start() }
        publishDebugState()
        startDebugServerIfNeeded()
    }

    var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    /// Smoothing is a feel setting, so it applies at once and survives a
    /// restart. Turning it off posts whatever was mid-glide.  The stored key
    /// still says pointer; it predates scrolling and renaming it would reset a
    /// choice already made.
    func setSmoothCursor(_ on: Bool) {
        smoothCursor = on
        UserDefaults.standard.set(on, forKey: "pointerSmoothing")
        pointerSmoothing.smoothsCursor = on
    }

    /// Below this, a move is posted whole. Raising it keeps smoothing for
    /// sweeps while slow aiming stays as direct as it was.
    func setSmoothingMinimum(_ points: Double) {
        smoothingMinimum = points
        UserDefaults.standard.set(points, forKey: "smoothingMinimumDelta")
        pointerSmoothing.minimumSmoothedDelta = points
    }

    func setSmoothScroll(_ on: Bool) {
        smoothScroll = on
        UserDefaults.standard.set(on, forKey: "scrollSmoothing")
        pointerSmoothing.smoothsScroll = on
    }

    /// Applies to the next press; an utterance already under way keeps the
    /// list it opened with, because the recogniser will not be re-biased
    /// mid-stream.
    func setScreenVocabulary(_ on: Bool) {
        screenVocabulary = on
        UserDefaults.standard.set(on, forKey: "screenVocabulary")
        screenVocabularyReader.isEnabled = on
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

    func tick() {
        pairingOffer.tick()
        central.tick()
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
        central.setLinkAuthenticated(true)
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
                if decrypted.messageType == MessageType.pointerDelta.rawValue,
                   decrypted.plaintext.starts(with: PointerStreamFrame.magic) {
                    try dispatchCursorFrame(PointerStreamFrame.decode(decrypted.plaintext))
                    return
                }
                let envelope = try ProtocolCodec.decode(Array(decrypted.plaintext))
                try dispatchApplication(envelope.payload)
            }
        } catch {
            lastApplicationMessage = "error"
        }
    }

    /// Compact cursor frames carry the same deltas as the JSON envelope and go
    /// through the same safety policy; only the encoding is cheaper.
    private func dispatchCursorFrame(_ frame: PointerStreamFrame) throws {
        for item in frame.items {
            switch item.kind {
            case .pointer:
                try dispatchApplication(.pointerDelta(PointerDeltaPayload(
                    deltaX: item.deltaX,
                    deltaY: item.deltaY
                )))
            case .scroll:
                try dispatchApplication(.scrollDelta(ScrollDeltaPayload(
                    deltaX: item.deltaX,
                    deltaY: item.deltaY
                )))
            }
        }
    }

    private func dispatchApplication(_ payload: MessagePayload) throws {
        switch payload {
        case let .heartbeat(value):
            // Not a command: it says what the phone believes it is holding.
            // Reconcile posts only the difference, so a press or release lost
            // on the way is repaired here rather than stranding the button.
            // Deliberately silent on `lastApplicationMessage`; four of these a
            // second would bury everything else.
            reliableInput.receive(heartbeat: InputHeartbeat(
                held: SharedInputProtocolAdapter.held(from: value)
            ))
        case .ping:
            try sendApplication(.pong(PongPayload()))
            lastApplicationMessage = "Pong sent"
        case .pong:
            lastApplicationMessage = "pong"
            return
        case let .appSwitcher(value):
            var applied = true
            for command in SharedInputProtocolAdapter.commands(for: value.phase) {
                if injector.submit(command) != .applied { applied = false }
            }
            lastApplicationMessage = applied ? "appSwitcher \(value.phase)" : "appSwitcher blocked"
        case let .deleteScrub(value):
            // Several messages make up one press, so this needs the memory the
            // coordinator holds; every event it posts still goes through the
            // injector and the same policy checks.
            lastApplicationMessage = deleteScrub.handle(value)
        default:
            let isCursor = payload.messageType == .pointerDelta
                || payload.messageType == .scrollDelta
                || payload.messageType == .motionPointerDelta
            if let command = try? SharedInputProtocolAdapter.command(for: payload) {
                switch injector.submit(command) {
                case .applied:
                    if isCursor { countCursorEvent() } else { lastApplicationMessage = String(describing: payload.messageType) }
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

    /// The watchdog needs a clock of its own: a phone that has stopped talking
    /// sends nothing to notice, which is the whole point of it.
    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogPollInterval,
            repeats: true
        ) { [weak self] timer in
            let stillOwned = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.pollWatchdog()
                return true
            }
            if !stillOwned { timer.invalidate() }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func pollWatchdog() {
        guard reliableInput.poll().contains(.watchdogExpired) else { return }
        lastApplicationMessage = "held input released: no heartbeat"
        publishDebugState()
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
        // A press whose end never arrived must not restore its characters into
        // whatever the next session is pointed at.
        deleteScrub.abandon()
        pairingServer = nil
        pairingID = nil
        pairingDeviceName = nil
        authenticatedSession = nil
        central.setLinkAuthenticated(false)
        lastApplicationMessage = nil
        inboundReassembler?.reset()
        controlReassembler?.reset()
        publishDebugState()
    }

    private func startDebugServerIfNeeded() {
        if MacHostRuntime.isInert { return }
        if ProcessInfo.processInfo.environment["PHONE_REMOTE_DEBUG_SERVER"] == "0" { return }
        let server = MacDebugHTTPServer(box: debugSnapshotBox)
        let reader = focusedTextReader
        server.focusProbe = { reader.diagnostics() }
        let vocabulary = screenVocabularyReader
        server.vocabularyProbe = { vocabulary.probe(bundleID: $0) }
        server.start()
        debugServer = server
    }

    private func publishDebugState() {
        lastCursorPublish = ProcessInfo.processInfo.systemUptime
        debugSnapshotBox.update(makeDebugSnapshot())
    }

    /// The counter is not `@Published`, so cursor traffic republishes the
    /// snapshot at 2 Hz for `debug-mac.sh` and never touches SwiftUI.
    private func countCursorEvent() {
        cursorEvents &+= 1
        guard ProcessInfo.processInfo.systemUptime - lastCursorPublish >= 0.5 else { return }
        publishDebugState()
    }

    private var vocabularyLabel: String {
        guard screenVocabulary else { return "off" }
        let walk = screenVocabularyReader.lastWalk
        guard walk.nodes > 0 else { return "on" }
        return "\(walk.milliseconds)ms/\(walk.nodes)nodes\(walk.truncated ? "+" : "")/\(walk.phrases)words"
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
            deleteScrub: deleteScrub.lastSlide.isEmpty ? nil : deleteScrub.lastSlide,
            keyPostMs: inputSink.lastKeyBurstMilliseconds,
            cursorEvents: cursorEvents,
            audioPhase: voice.phase.rawValue,
            audioFrames: voice.health.receivedFrames,
            audioSamples: voice.health.receivedSamples,
            audioMissingChunks: voice.health.missingChunks,
            audioMerge: voice.merge,
            audioTiming: voice.timing,
            audioVocabulary: vocabularyLabel,
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

            Toggle("Boost words on screen", isOn: Binding(
                get: { model.screenVocabulary },
                set: { model.setScreenVocabulary($0) }
            ))
            .font(.caption)
            .help("Experimental. Reads names and jargon from the front window and nudges voice typing toward them. Skipped while a password field is focused.")

            Toggle("Smooth cursor", isOn: Binding(
                get: { model.smoothCursor },
                set: { model.setSmoothCursor($0) }
            ))
            .font(.caption)
            .help("Spreads each packet of movement over the next few frames. Smoother, with about one packet more lag.")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.smoothingMinimum == 0
                     ? "Smooth every move"
                     : "Skip moves under \(Int(model.smoothingMinimum)) points")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { model.smoothingMinimum },
                        set: { model.setSmoothingMinimum($0) }
                    ),
                    in: 0...30,
                    step: 1
                )
            }
            .disabled(!model.smoothCursor)
            .help("Small moves are slow, careful aiming. Posting those whole keeps them lag free, while fast sweeps still glide.")

            Toggle("Smooth scroll", isOn: Binding(
                get: { model.smoothScroll },
                set: { model.setSmoothScroll($0) }
            ))
            .font(.caption)
            .help("Off by default: splitting a scroll makes apps accelerate it less, so the page moves a shorter distance for the same flick.")

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
            model.tick()
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
