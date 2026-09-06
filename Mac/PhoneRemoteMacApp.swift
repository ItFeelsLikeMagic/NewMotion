import SwiftUI
import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

#if os(macOS)
import AppKit

private extension RemoteLinkState {
    var label: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .searching: return "Searching"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
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
    /// How long a connected phone has to finish the handshake. Nothing below
    /// can tell a healthy idle link from a stale one, so the deadline lives
    /// here, beside the session it is waiting for.
    private static let authenticationTimeout: TimeInterval = 12

    private let injector: SafeInputInjector
    private let reliableInput: ReliableInputCoordinator
    /// Runs only while a phone is authenticated.  The watchdog itself stays
    /// disarmed until a heartbeat arrives, so a remote that holds nothing is
    /// never at risk of a release it did not need.
    private var watchdogTimer: Timer?
    private let pointerSmoothing: SmoothedTravelSink
    private let inputSink: CGEventInputSink
    private let lifecycle: MacLifecycleCoordinator
    private let link: MessageLink
    private let pairingOffer: MacPairingOfferController
    private let pairingCoordinator: MacPairingCoordinator?
    private let qrRenderer: MacPairingQRCodeRenderer
    private var pairingServer: PairingHandshakeServer?
    /// The hello from a phone that scanned the QR code, held until the user
    /// answers the prompt. The offer is consumed only on Allow, so a phone
    /// that gives up first leaves the code usable.
    private var pendingHello: PairingClientHello?
    private let approvalWindow = MacPhoneApprovalWindow()
    private var authenticationDeadline: Date?
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
            refreshAuthenticationDeadline()
        }
    }
    private var nextApplicationSequence: UInt64 = 1

    @Published private(set) var status: RemoteMenuBarStatus = .disconnected { didSet { publishDebugState() } }
    @Published private(set) var accessibility: AccessibilityState = .unknown { didSet { publishDebugState() } }
    @Published private(set) var linkState: RemoteLinkState = .unavailable { didSet { publishDebugState() } }
    @Published private(set) var pairingState: MacPairingOfferState = .idle { didSet { publishDebugState() } }
    @Published private(set) var pairingProgress: MacPairingProgress = .idle { didSet { publishDebugState() } }
    /// Set while the Allow/Deny prompt is up for a phone with this name.
    @Published private(set) var pendingApprovalName: String?
    @Published private(set) var pairedDevices: [TrustedDeviceSummary] = [] { didSet { publishDebugState() } }
    @Published private(set) var pairingError: String? { didSet { publishDebugState() } }
    @Published private(set) var pairingQRImage: NSImage? { didSet { publishDebugState() } }
    @Published private(set) var pairingExpiry: Date? { didSet { publishDebugState() } }
    @Published private(set) var lastApplicationMessage: String? { didSet { publishDebugState() } }
    @Published private(set) var lastPairingFailure: String? { didSet { publishDebugState() } }
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
    private let screenVocabularyReader: AXScreenVocabularyReader
    /// The phone transcribes, so the cache has to reach it.  Held here as well
    /// as inside the reader, because spoken words are credited to it directly.
    private let vocabularyCache: VocabularyCache
    private var lastSentVocabulary: [String] = []
    private var vocabularyTimer: Timer?
    private var frontAppObserver: NSObjectProtocol?
    private let latency: MacLatencyProbes
    private let debugSnapshotBox = MacDebugSnapshotBox()
    private var debugServer: MacDebugHTTPServer?
    private let focusedTextReader = AXFocusedTextReader()
    private let deleteScrub: DeleteScrubCoordinator

    init() {
        let latency = MacLatencyProbes()
        self.latency = latency
        let vocabularyCache = VocabularyCache()
        let screenVocabularyReader = AXScreenVocabularyReader(
            isEnabled: UserDefaults.standard.object(forKey: "screenVocabulary") as? Bool ?? true,
            cache: vocabularyCache
        )
        self.screenVocabularyReader = screenVocabularyReader
        self.vocabularyCache = vocabularyCache
        let trust = SystemAccessibilityTrust()
        let sink = CGEventInputSink(trust: trust, keyPost: latency.keyPost)
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
        let link = BLEMessageLink(adapter: adapter, latency: latency.linkSend)
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
        self.link = link
        self.pairingOffer = pairingOffer
        self.pairingCoordinator = pairingCoordinator
        self.qrRenderer = MacPairingQRCodeRenderer()
        self.pairedDevices = pairingCoordinator?.trustedDevices ?? []

        // Core Bluetooth already calls back on the main queue.  A `Task` hop
        // per message queued every packet behind whatever the main actor was
        // doing, so a burst of cursor motion replayed slowly instead of
        // arriving.  The same fix was needed for the phone's motion sink.
        link.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.handleLinkState(state) }
        }
        link.onMessage = { [weak self] channel, message in
            // Started here rather than deeper in, so the number covers
            // everything the Mac does with a message the phone has already sent.
            let arrival = LatencyClock()
            MainActor.assumeIsolated {
                self?.handleIncomingMessage(channel: channel, message: message, arrival: arrival)
            }
        }
        link.onError = { [weak self] error in
            MainActor.assumeIsolated { self?.handleLinkError(error) }
        }
        handleLinkState(link.state)
        pairingOffer.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.pairingState = state
                guard let self else { return }
                if case .active = state {
                    self.pairingProgress = .waitingForScan
                    return
                }
                // An offer that expired under the prompt cannot be allowed.
                self.dismissApproval()
                self.pairingQRImage = nil
                self.pairingExpiry = nil
                if self.authenticatedSession == nil {
                    self.pairingProgress = self.linkProgress(for: self.link.state)
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

        if !inert {
            screenVocabularyReader.warmUp()
            startVocabularyPush()
        }

        _ = lifecycle.handle(.startup)
        refreshAccessibility(prompt: false)
        if !inert { link.start() }
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
            pairingProgress = .waitingForScan
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
        guard let deadline = authenticationDeadline, Date() >= deadline else { return }
        // A connected phone that never finishes the handshake leaves a link
        // that looks live and carries nothing. Drop it and look again.
        authenticationDeadline = nil
        link.stop()
        link.start()
    }

    private func updateStatus() {
        status = lifecycle.status()
    }

    private func handleLinkState(_ state: RemoteLinkState) {
        linkState = state
        if state != .connected, authenticatedSession != nil {
            clearHandshakeState()
            _ = lifecycle.handle(.disconnected)
            updateStatus()
        }
        if state != .connected, pendingHello != nil {
            // The phone left while the prompt was up. Its code was never
            // consumed, so it can scan again.
            dismissApproval()
            pairingProgress = .waitingForScan
        }
        refreshAuthenticationDeadline()
        // A live QR offer is its own progress; the link looking behind it is
        // not news.
        if case .active = pairingOffer.state, state == .searching { return }
        pairingProgress = linkProgress(for: state)
    }

    private func linkProgress(for state: RemoteLinkState) -> MacPairingProgress {
        switch state {
        case .unavailable: return .waitingForLink
        case .searching: return .scanning
        case .connecting: return .connecting(deviceName: peerName)
        case .connected:
            if authenticatedSession != nil {
                return .paired(deviceName: pairingDeviceName ?? peerName)
            }
            return .connected(deviceName: peerName)
        }
    }

    /// Paused while the prompt is up: there the Mac's user is the one being
    /// waited on, and a phone dropped mid-decision would only scan again.
    private func refreshAuthenticationDeadline() {
        guard link.state == .connected, authenticatedSession == nil, pendingHello == nil else {
            authenticationDeadline = nil
            return
        }
        authenticationDeadline = Date().addingTimeInterval(Self.authenticationTimeout)
    }

    private var peerName: String { link.peerName ?? "iPhone" }

    private func handleIncomingMessage(channel: LinkChannel, message: Data, arrival: LatencyClock) {
        switch channel {
        case .data:
            guard authenticatedSession != nil else { return }
            handleApplicationMessage(message, arrival: arrival)
        case .control:
            handleControlMessage(message)
        }
    }

    /// A hello is accepted even when the Mac already thought it was paired;
    /// otherwise the phone retries forever and ping/trackpad stay dead.
    private func handleControlMessage(_ message: Data) {
        do {
            if message.starts(with: PairingClientHello.magic) {
                pairingServer = nil
                try beginHandshake(payload: message)
            } else if message.starts(with: PairingClientFinish.magic) {
                guard let pairingServer else { throw PairingError.invalidHandshake }
                try finishHandshake(server: pairingServer, payload: message)
            } else if authenticatedSession == nil {
                throw PairingError.invalidHandshake
            }
        } catch {
            failPairing(error)
        }
    }

    /// A phone presenting the displayed code is new to this Mac, so its hello
    /// waits for the user. A trusted phone reconnecting was allowed once
    /// already and goes straight through.
    private func beginHandshake(payload: Data) throws {
        guard let pairingCoordinator else { throw PairingError.tokenNotActive }
        let hello = try PairingClientHello.decode(payload)
        if pairingOffer.activePairingID == hello.pairingID {
            // The phone repeats its hello while it waits; one prompt covers them all.
            guard pendingHello?.pairingID != hello.pairingID else { return }
            holdForApproval(hello)
            return
        }
        let server = try pairingCoordinator.makeReconnectServer(for: hello.pairingID)
        try startHandshake(server: server, hello: hello)
    }

    private func holdForApproval(_ hello: PairingClientHello) {
        let name = peerName
        pendingHello = hello
        pendingApprovalName = name
        refreshAuthenticationDeadline()
        pairingProgress = .awaitingApproval(deviceName: name)
        approvalWindow.show(
            deviceName: name,
            onAllow: { [weak self] in self?.allowPendingPhone() },
            onDeny: { [weak self] in self?.denyPendingPhone() }
        )
    }

    func allowPendingPhone() {
        guard let hello = pendingHello, let pairingCoordinator else { return }
        dismissApproval()
        do {
            let server = try pairingCoordinator.makeOneTimeServer(pairingID: hello.pairingID)
            try startHandshake(server: server, hello: hello)
        } catch {
            failPairing(error)
        }
    }

    /// The phone drops the link when it reads the decline; the authentication
    /// deadline, resumed here, drops it for a phone that does not.
    func denyPendingPhone() {
        guard let hello = pendingHello else { return }
        dismissApproval()
        pairingOffer.cancel()
        _ = link.send(PairingServerDecline(pairingID: hello.pairingID).encode(), on: .control, delivery: .reliable)
        refreshAuthenticationDeadline()
        lastApplicationMessage = "Declined \(peerName)"
    }

    private func dismissApproval() {
        approvalWindow.close()
        pendingHello = nil
        pendingApprovalName = nil
    }

    private func startHandshake(server: PairingHandshakeServer, hello: PairingClientHello) throws {
        pairingID = hello.pairingID
        pairingDeviceName = peerName
        pairingServer = server
        if authenticatedSession == nil {
            pairingProgress = .authenticating(deviceName: peerName)
        }
        let response = try server.accept(clientHelloData: hello.encode())
        try sendHandshake(response.response)
    }

    private func finishHandshake(server: PairingHandshakeServer, payload: Data) throws {
        guard let pairingCoordinator, let pairingID else { throw PairingError.invalidHandshake }
        let result = try server.accept(clientFinishData: payload)
        let displayName = pairingDeviceName ?? peerName
        _ = try pairingCoordinator.rememberPairedPhone(
            deviceID: pairingID,
            displayName: displayName,
            peerIdentityPublicKey: result.peerIdentityPublicKey
        )
        pairedDevices = pairingCoordinator.trustedDevices
        authenticatedSession = result.session
        pushVocabulary(force: true)
        pairingServer = nil
        pairingError = nil
        lastPairingFailure = nil
        pairingProgress = .paired(deviceName: displayName)
        nextApplicationSequence = 1
        lastApplicationMessage = nil
        _ = lifecycle.handle(.authenticated)
        updateStatus()
    }

    private func sendHandshake(_ payload: Data) throws {
        guard link.send(payload, on: .control, delivery: .reliable) == .sent else {
            throw PairingError.invalidHandshake
        }
    }

    private func handleLinkError(_ error: LinkError) {
        if authenticatedSession != nil {
            clearHandshakeState()
            _ = lifecycle.handle(.disconnected)
            updateStatus()
            pairingProgress = .disconnected
            return
        }
        if pairingServer != nil {
            failPairing(error)
            return
        }
        // The phone vanished before hello, or under the prompt. Keep the QR
        // offer and wait again.
        dismissApproval()
        updateStatus()
        if case .active = pairingOffer.state {
            pairingProgress = .waitingForScan
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
        case let link as LinkError:
            return linkFailureName(link)
        case .some:
            return "handshake"
        case .none:
            return nil
        }
    }

    private static func linkFailureName(_ error: LinkError) -> String {
        switch error {
        case .unavailable: return "Bluetooth turned off"
        case .peerNotFound: return "the phone never answered"
        case let .setupFailed(reason): return reason
        case .peerDisconnected: return "the phone disconnected"
        case .malformedMessage: return "an unreadable message"
        }
    }

    /// `arrival` is stopped once the events are with the injector, so
    /// `receiveToInject` is the Mac's whole share of the lag. The stages inside
    /// it are timed separately, which is what localises a regression; a message
    /// that never reaches the injector is a refusal rather than a fast one.
    private func handleApplicationMessage(_ message: Data, arrival: LatencyClock) {
        guard let session = authenticatedSession else { return }
        do {
            let unsealing = LatencyClock()
            let decrypted = try session.decrypt(message)
            latency.decrypt.record(microseconds: unsealing.elapsedMicroseconds)
            let decoding = LatencyClock()
            if decrypted.messageType == MessageType.pointerDelta.rawValue,
               decrypted.plaintext.starts(with: PointerStreamFrame.magic) {
                let frame = try PointerStreamFrame.decode(decrypted.plaintext)
                latency.decode.record(microseconds: decoding.elapsedMicroseconds)
                let handing = LatencyClock()
                try dispatchCursorFrame(frame)
                latency.dispatch.record(microseconds: handing.elapsedMicroseconds)
                latency.receiveToInject.record(microseconds: arrival.elapsedMicroseconds)
                return
            }
            let envelope = try ProtocolCodec.decode(Array(decrypted.plaintext))
            latency.decode.record(microseconds: decoding.elapsedMicroseconds)
            let handing = LatencyClock()
            try dispatchApplication(envelope.payload)
            latency.dispatch.record(microseconds: handing.elapsedMicroseconds)
            latency.receiveToInject.record(microseconds: arrival.elapsedMicroseconds)
        } catch {
            latency.receiveToInject.recordRefusal()
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
        case let .tabWalk(value):
            var applied = true
            for command in SharedInputProtocolAdapter.commands(for: value) {
                if injector.submit(command) != .applied { applied = false }
            }
            lastApplicationMessage = applied
                ? "tabWalk \(value.modifier) \(value.phase)"
                : "tabWalk blocked"
        case let .spokenText(value):
            // Dictation carries the risk the old transcript path did: never
            // type into a secure field. Words actually spoken are also what
            // buy a phrase its three-hour lease, so the cache is credited
            // here, which is the only place that now knows they were said.
            guard let text = value.text else {
                lastApplicationMessage = "Spoken text refused"
                return
            }
            guard !SecureInput.isActive() else {
                lastApplicationMessage = "Spoken text held back"
                return
            }
            vocabularyCache.heard(text)
            lastApplicationMessage = injector.submit(.text(text)) == .applied
                ? "Typed spoken text"
                : "Spoken text blocked"
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

    /// Transcription moved to the phone, so the boost list has to arrive
    /// before a press rather than being read during one.  The walk still
    /// happens here, because only this side can see this screen; what changed
    /// is that the answer travels.
    ///
    /// Two triggers and no press-time round trip: the front window changing is
    /// what actually changes the words, and the timer is the catch-all for
    /// everything that changes inside a window that stays frontmost.
    private func startVocabularyPush() {
        frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushVocabulary() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushVocabulary() }
        }
        timer.tolerance = 2
        vocabularyTimer = timer
    }

    /// Sends the current list when it differs from the last one the phone was
    /// given.  An unpaired or secure screen sends nothing at all.
    private func pushVocabulary(force: Bool = false) {
        guard authenticatedSession != nil else { return }
        // The provider promises to call back but says nothing about where, so
        // this hops rather than asserting it is already on the main actor.
        screenVocabularyReader.speechContext { [weak self] phrases in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let bounded = VocabularyPayload.bounded(phrases)
                guard force || bounded != self.lastSentVocabulary else { return }
                guard let payload = try? VocabularyPayload(phrases: bounded) else { return }
                do {
                    try self.sendApplication(.vocabulary(payload))
                    self.lastSentVocabulary = bounded
                } catch {
                    // The link will be back; the next trigger re-sends.
                }
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
        let sealed = try session.seal(envelope)
        guard link.send(sealed, on: .data, delivery: envelope.messageType.deliveryClass == .reliable ? .reliable : .unreliableQueued) == .sent else {
            throw PairingError.invalidHandshake
        }
    }

    private func clearHandshakeState() {
        // A press whose end never arrived must not restore its characters into
        // whatever the next session is pointed at.
        deleteScrub.abandon()
        dismissApproval()
        pairingServer = nil
        pairingID = nil
        pairingDeviceName = nil
        authenticatedSession = nil
        lastApplicationMessage = nil
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
        let probes = latency
        server.latencyProbe = { probes.summaries() }
        let keys = MainThreadInjector(injector: injector)
        server.keyBurstProbe = { count in
            MacRemoteAppModel.measureKeyBurst(count, keys: keys.injector, reader: reader)
        }
        server.start()
        debugServer = server
    }

    /// Carries the injector to the debug probe.  Both are main-thread only:
    /// the probe is hopped there before it runs, which is what makes this safe.
    private struct MainThreadInjector: @unchecked Sendable {
        let injector: SafeInputInjector
    }

    /// Presses Delete `asked` times as one burst and reports how many
    /// characters the focused field actually lost.  It is the only honest way to
    /// settle how much spacing a run of one repeated key needs; the numbers are
    /// lengths and milliseconds, never text.
    nonisolated private static func measureKeyBurst(
        _ asked: Int,
        keys: SafeInputInjector,
        reader: FocusedTextReading
    ) -> [String: String] {
        let wanted = min(max(asked, 1), InputPolicyLimits().maxHotkeyRun)
        // It types its own filler so the count is known and the caret is left
        // where a delete key would find it.  Point this at a scratch window.
        let filler = String(repeating: "abcdefghij", count: (wanted / 10) + 2)
        guard keys.submit(.text(filler)) == .applied else {
            return ["error": "filler refused"]
        }
        Thread.sleep(forTimeInterval: 0.5)
        guard case let .split(before, _) = reader.textAroundCaret() else {
            return ["error": "field unreadable"]
        }
        guard before.count >= wanted else {
            return ["error": "filler did not land", "typed": String(filler.count), "read": String(before.count)]
        }
        let started = ProcessInfo.processInfo.systemUptime
        let result = keys.submit(.hotkeyRun(.deleteBackward, times: wanted))
        // Long enough for the whole burst to be posted and taken in.  The app
        // being typed into runs on its own, so sleeping here does not hold it up.
        Thread.sleep(forTimeInterval: 0.8)
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        guard case let .split(after, _) = reader.textAroundCaret() else {
            return ["error": "field unreadable after"]
        }
        return [
            "asked": String(wanted),
            "removed": String(before.count - after.count),
            "filler": String(filler.count),
            "before": String(before.count),
            "after": String(after.count),
            "result": String(describing: result),
            "elapsedMs": String(format: "%.0f", elapsed)
        ]
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
            link: linkState.label,
            linkKind: String(describing: linkState),
            pairingProgress: pairingProgress.title,
            pairingProgressKind: pairingProgress.kind,
            authenticated: authenticatedSession != nil || pairingProgress.isAuthenticated,
            pairingOffer: offer,
            hasPairingQR: pairingQRImage != nil,
            pairingError: pairingError,
            lastPairingFailure: lastPairingFailure,
            peerName: peerName,
            lastApplicationMessage: lastApplicationMessage,
            deleteScrub: deleteScrub.lastSlide.isEmpty ? nil : deleteScrub.lastSlide,
            keyPostMs: inputSink.lastKeyBurstMilliseconds,
            cursorEvents: cursorEvents,
            vocabulary: vocabularyLabel,
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
            LabeledContent("Connection", value: model.linkState.label)
                .font(.caption)
            Label(model.pairingProgress.title,
                  systemImage: model.pairingProgress.isAuthenticated ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(model.pairingProgress.isAuthenticated ? .green : .secondary)
            if let name = model.pendingApprovalName {
                HStack {
                    Button("Allow \(name)") { model.allowPendingPhone() }
                        .buttonStyle(.borderedProminent)
                    Button("Don't Allow") { model.denyPendingPhone() }
                }
            }
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

            Divider()
            // This app has no Dock icon and no menu bar of its own, so this is
            // the only way out of it that is not Activity Monitor.
            Button("Quit Phone Remote") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
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
