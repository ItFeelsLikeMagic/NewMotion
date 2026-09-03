import Foundation

public protocol MicrophoneInputProviding: AnyObject {
    func requestPermission(completion: @Sendable @escaping (Bool) -> Void)
    /// Brings the audio path up ahead of any press, so `start` only has to
    /// attach the sample handler.  Idempotent and best effort.
    func prewarm()
    func start(samples: @Sendable @escaping ([Int16]) -> Void) throws
    /// Stops delivering samples but keeps the audio path warm for the next press.
    func stop()
    /// Gives the audio session back to the system; the app is leaving the foreground.
    func suspend()
}

public extension MicrophoneInputProviding {
    func prewarm() {}
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
    private var stateMachine: AudioCaptureStateMachine
    private var chunker: PCM16Chunker
    private var pendingRelease: DispatchWorkItem?

    public var onUtteranceStart: (@Sendable () -> Void)?
    public var onChunk: (@Sendable ([Int16]) -> Void)?
    public var onUtteranceEnd: (@Sendable () -> Void)?

    /// `releaseGrace` keeps the microphone open briefly after the finger lifts,
    /// because people let go while the last syllable is still sounding.
    public init(
        microphone: MicrophoneInputProviding,
        queue: DispatchQueue = DispatchQueue(label: "phoneremote.voice"),
        chunker: PCM16Chunker = PCM16Chunker(),
        permissionGranted: Bool = false,
        releaseGrace: TimeInterval = 0.15
    ) {
        self.queue = queue
        self.microphone = microphone
        self.releaseGrace = releaseGrace
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
        queue.async {
            self.apply(self.stateMachine.setPermissionGranted(granted))
            self.prewarmNow()
        }
    }

    /// Holds the audio session and engine open for the whole foreground
    /// session.  Buffers that arrive outside an utterance are dropped by
    /// `receive`, so a press costs only the state change.
    public func prewarm() {
        queue.async { self.prewarmNow() }
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
            self.microphone.suspend()
        }
    }

    /// The warm engine is bound to the input that just disappeared, so it has
    /// to be torn down and brought back up on the new route.
    public func routeChanged() {
        queue.async {
            self.stopNow(.routeChanged)
            self.microphone.suspend()
            self.prewarmNow()
        }
    }

    /// Synchronous so the end frame is handed to the transport before the
    /// caller tears the transport down.
    public func applicationDidEnterBackground() {
        queue.sync {
            stopNow(.appBackgrounded)
            microphone.suspend()
        }
    }

    public func applicationWillEnterForeground() {
        queue.async {
            self.stateMachine.handle(.appForegrounded)
            self.prewarmNow()
        }
    }

    private func prewarmNow() {
        guard stateMachine.appForegrounded, stateMachine.permissionGranted else { return }
        microphone.prewarm()
    }

    private func stopNow(_ event: AudioCaptureEvent) {
        pendingRelease?.cancel()
        pendingRelease = nil
        apply(stateMachine.handle(event))
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
        }
    }
}

#if os(iOS)
import AVFoundation

/// AVFoundation adapter.  It is created only by the iPhone app target; tests
/// inject a MicrophoneInputProviding fake and never touch the microphone.
/// The session, engine and input tap stay up for the whole foreground
/// session, so a press only attaches the sample handler; `suspend()` hands
/// the session back when the app leaves the foreground.
public final class AVAudioMicrophoneInput: MicrophoneInputProviding, @unchecked Sendable {
    private let session: AVAudioSession
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    /// Guards `handler` only; it is set on the voice queue and read on the tap thread.
    private let handlerLock = NSLock()
    private var handler: (@Sendable ([Int16]) -> Void)?
    private var converter: AVAudioConverter?
    private var sessionConfigured = false
    private var running = false

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

    public func prewarm() {
        try? bringUp()
    }

    public func start(samples: @Sendable @escaping ([Int16]) -> Void) throws {
        try bringUp()
        handlerLock.lock()
        handler = samples
        handlerLock.unlock()
    }

    public func stop() {
        handlerLock.lock()
        handler = nil
        handlerLock.unlock()
    }

    public func suspend() {
        stop()
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Idempotent.  Everything slow lives here: activating the session and
    /// starting the engine cost 250-400 ms, which is the whole press-to-audio
    /// delay when it happens under the finger instead of ahead of it.
    private func bringUp() throws {
        guard !running else { return }
        if !sessionConfigured {
            // `mixWithOthers` is what makes holding the session open all
            // session long acceptable: other apps keep playing.  The hardware
            // rate is left alone because the converter resamples anyway, and
            // asking for 16 kHz only buys a slow route reconfiguration.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .defaultToSpeaker]
            )
            try session.setPreferredIOBufferDuration(0.02)
            // The session is held open for the whole app run, and iOS mutes the
            // Taptic Engine for as long as one is recording.  Without this every
            // buzz in the UI is silently dropped, not just the ones while the
            // microphone is live.  It resets whenever the category is set, so it
            // belongs here rather than at launch.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            sessionConfigured = true
        }
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let created = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.formatUnavailable
        }
        converter = created
        IPhoneDebugLog.emit("ptt_mic", [
            "route": session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+"),
            "rate": "\(Int(inputFormat.sampleRate))",
            "ch": "\(inputFormat.channelCount)",
            "gain": "\(session.inputGain)",
            "avail": session.isInputAvailable ? "yes" : "no",
            "haptics": session.allowHapticsAndSystemSoundsDuringRecording ? "yes" : "no",
        ])
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    private func convert(buffer: AVAudioPCMBuffer) {
        handlerLock.lock()
        let handler = self.handler
        handlerLock.unlock()
        guard let handler, let converter else { return }
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
