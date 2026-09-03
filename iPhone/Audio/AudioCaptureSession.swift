import Foundation

public protocol MicrophoneInputProviding: AnyObject {
    func requestPermission(completion: @Sendable @escaping (Bool) -> Void)
    func start(samples: @Sendable @escaping ([Int16]) -> Void) throws
    /// Stops delivering samples but keeps the audio path warm for the next press.
    func stop()
    /// Gives the audio session back to the system; the app is leaving the foreground.
    func suspend()
}

public enum AudioCaptureStartResult: Equatable, Sendable {
    case started
    case permissionDenied
    case notForeground
    case failed
}

/// Owns the local push-to-talk gesture and turns normalized mono samples into
/// fixed-size 16 kHz PCM chunks.  Every state change, the microphone start and
/// stop, and every callback run on `queue`, so the tap thread and the main
/// thread never touch the chunker or state machine concurrently.
public final class LocalPushToTalkAudioController: @unchecked Sendable {
    public let queue: DispatchQueue
    private let microphone: MicrophoneInputProviding
    private let releaseGrace: TimeInterval
    private let idleRelease: TimeInterval
    private var stateMachine: AudioCaptureStateMachine
    private var chunker: PCM16Chunker
    private var pendingRelease: DispatchWorkItem?
    private var pendingSuspend: DispatchWorkItem?

    public var onUtteranceStart: (@Sendable () -> Void)?
    public var onChunk: (@Sendable ([Int16]) -> Void)?
    public var onUtteranceEnd: (@Sendable () -> Void)?

    /// `releaseGrace` keeps the microphone open briefly after the finger lifts,
    /// because people let go while the last syllable is still sounding.
    /// `idleRelease` is how long the audio session stays warm after an
    /// utterance before it is handed back to the system.
    public init(
        microphone: MicrophoneInputProviding,
        queue: DispatchQueue = DispatchQueue(label: "phoneremote.voice"),
        chunker: PCM16Chunker = PCM16Chunker(),
        permissionGranted: Bool = false,
        releaseGrace: TimeInterval = 0.15,
        idleRelease: TimeInterval = 2
    ) {
        self.queue = queue
        self.microphone = microphone
        self.releaseGrace = releaseGrace
        self.idleRelease = idleRelease
        self.stateMachine = AudioCaptureStateMachine(permissionGranted: permissionGranted)
        self.chunker = chunker
    }

    public var state: AudioCaptureState { queue.sync { stateMachine.state } }

    public func requestPermission(completion: @Sendable @escaping (Bool) -> Void) {
        microphone.requestPermission { [weak self] granted in
            self?.setPermissionGranted(granted)
            completion(granted)
        }
    }

    public func setPermissionGranted(_ granted: Bool) {
        queue.async { self.apply(self.stateMachine.setPermissionGranted(granted)) }
    }

    /// The start frame goes out before the microphone starts so the Mac can
    /// open its recognizer while the audio session is still warming up.
    public func pushToTalkPressed(completion: @Sendable @escaping (AudioCaptureStartResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let pendingRelease {
                // Re-pressed inside the grace window: the utterance simply continues.
                pendingRelease.cancel()
                self.pendingRelease = nil
                completion(.started)
                return
            }
            pendingSuspend?.cancel()
            pendingSuspend = nil
            let actions = stateMachine.handle(.localPushToTalkPressed)
            guard actions.contains(.startCapture) else {
                completion(stateMachine.appForegrounded ? .permissionDenied : .notForeground)
                return
            }
            onUtteranceStart?()
            do {
                try microphone.start { [weak self] samples in
                    guard let self else { return }
                    queue.async { self.receive(samples) }
                }
                completion(.started)
            } catch {
                apply(stateMachine.handle(.localCancel))
                completion(.failed)
            }
        }
    }

    public func pushToTalkReleased() {
        queue.async {
            guard self.stateMachine.state == .capturing, self.pendingRelease == nil else { return }
            guard self.releaseGrace > 0 else {
                self.apply(self.stateMachine.handle(.localPushToTalkReleased))
                return
            }
            let release = DispatchWorkItem {
                self.pendingRelease = nil
                self.apply(self.stateMachine.handle(.localPushToTalkReleased))
            }
            self.pendingRelease = release
            self.queue.asyncAfter(deadline: .now() + self.releaseGrace, execute: release)
        }
    }

    public func cancel() {
        queue.async { self.stopNow(.localCancel) }
    }

    public func interruptionBegan() {
        queue.async {
            self.stopNow(.interruptionBegan)
            self.suspendNow()
        }
    }

    public func routeChanged() {
        queue.async { self.stopNow(.routeChanged) }
    }

    /// Synchronous so the end frame is handed to the transport before the
    /// caller tears the transport down.
    public func applicationDidEnterBackground() {
        queue.sync {
            stopNow(.appBackgrounded)
            suspendNow()
        }
    }

    private func suspendNow() {
        pendingSuspend?.cancel()
        pendingSuspend = nil
        microphone.suspend()
    }

    private func stopNow(_ event: AudioCaptureEvent) {
        pendingRelease?.cancel()
        pendingRelease = nil
        apply(stateMachine.handle(event))
    }

    public func applicationWillEnterForeground() {
        queue.async { self.stateMachine.handle(.appForegrounded) }
    }

    private func receive(_ samples: [Int16]) {
        guard stateMachine.state == .capturing else { return }
        for chunk in chunker.append(samples) {
            onChunk?(chunk)
        }
    }

    private func apply(_ actions: [AudioCaptureAction]) {
        for action in actions where action == .stopCapture {
            if let chunk = chunker.flush() {
                onChunk?(chunk)
            }
            onUtteranceEnd?()
            microphone.stop()
            scheduleIdleSuspend()
        }
    }

    private func scheduleIdleSuspend() {
        guard idleRelease > 0 else {
            microphone.suspend()
            return
        }
        let suspend = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingSuspend = nil
            microphone.suspend()
        }
        pendingSuspend = suspend
        queue.asyncAfter(deadline: .now() + idleRelease, execute: suspend)
    }
}

#if os(iOS)
import AVFoundation

/// AVFoundation adapter.  It is created only by the iPhone app target; tests
/// inject a MicrophoneInputProviding fake and never touch the microphone.
/// The engine and converter stay warm for the life of the app, and the
/// session stays active between quick successive presses; `suspend()` hands
/// the session back once the controller decides the user is done talking.
public final class AVAudioMicrophoneInput: MicrophoneInputProviding {
    private let session: AVAudioSession
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private var converter: AVAudioConverter?
    private var sessionConfigured = false
    private var sessionActive = false

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    public func requestPermission(completion: @Sendable @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }

    public func start(samples: @Sendable @escaping ([Int16]) -> Void) throws {
        if !sessionConfigured {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(0.02)
            sessionConfigured = true
        }
        if !sessionActive {
            try session.setActive(true)
            sessionActive = true
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if converter?.inputFormat != inputFormat {
            guard let created = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioCaptureError.formatUnavailable
            }
            converter = created
        }
        IPhoneDebugLog.emit("ptt_mic", [
            "route": session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+"),
            "rate": "\(Int(inputFormat.sampleRate))",
            "ch": "\(inputFormat.channelCount)",
            "gain": "\(session.inputGain)",
            "avail": session.isInputAvailable ? "yes" : "no",
        ])
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, handler: samples)
        }
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.pause()
    }

    public func suspend() {
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    private func convert(buffer: AVAudioPCMBuffer, handler: ([Int16]) -> Void) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 1))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.int16ChannelData else { return }
        handler(Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))))
    }
}

public enum AudioCaptureError: Error, Equatable, Sendable {
    case formatUnavailable
}
#endif
