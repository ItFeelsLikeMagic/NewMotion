import Foundation

public protocol MicrophoneInputProviding: AnyObject {
    func requestPermission(completion: @Sendable @escaping (Bool) -> Void)
    func start(samples: @Sendable @escaping ([Int16], TimeInterval) -> Void) throws
    func stop()
}

public enum AudioCaptureStartResult: Equatable, Sendable {
    case started
    case permissionDenied
    case notForeground
    case failed
}

/// Owns the local push-to-talk gesture and turns normalized mono samples into
/// bounded 16 kHz PCM chunks.  There is intentionally no remote-start method.
public final class LocalPushToTalkAudioController: @unchecked Sendable {
    private let microphone: MicrophoneInputProviding
    private var stateMachine: AudioCaptureStateMachine
    private var chunker: PCM16Chunker

    public var onChunk: (@Sendable (CapturedPCM16Chunk) -> Void)?
    public var onLevel: (@Sendable (Double) -> Void)?
    public var onUtteranceEnd: (@Sendable () -> Void)?

    public init(
        microphone: MicrophoneInputProviding,
        chunker: PCM16Chunker = PCM16Chunker(),
        permissionGranted: Bool = false
    ) {
        self.microphone = microphone
        self.stateMachine = AudioCaptureStateMachine(permissionGranted: permissionGranted)
        self.chunker = chunker
    }

    public var state: AudioCaptureState { stateMachine.state }
    public var isCapturing: Bool { state == .capturing }

    public func requestPermission(completion: @Sendable @escaping (Bool) -> Void) {
        microphone.requestPermission { [weak self] granted in
            _ = self?.setPermissionGranted(granted)
            completion(granted)
        }
    }

    @discardableResult
    public func setPermissionGranted(_ granted: Bool) -> [AudioCaptureAction] {
        let actions = stateMachine.setPermissionGranted(granted)
        apply(actions)
        return actions
    }

    @discardableResult
    public func pushToTalkPressed() -> AudioCaptureStartResult {
        let actions = stateMachine.handle(.localPushToTalkPressed)
        guard actions.contains(.startCapture) else {
            return stateMachine.appForegrounded ? .permissionDenied : .notForeground
        }
        do {
            try microphone.start { [weak self] samples, timestamp in
                self?.receive(samples: samples, timestamp: timestamp)
            }
            return .started
        } catch {
            microphone.stop()
            _ = stateMachine.handle(.localCancel)
            return .failed
        }
    }

    public func pushToTalkReleased() {
        apply(stateMachine.handle(.localPushToTalkReleased))
    }

    public func cancel() {
        apply(stateMachine.handle(.localCancel))
    }

    public func interruptionBegan() {
        apply(stateMachine.handle(.interruptionBegan))
    }

    public func routeChanged() {
        apply(stateMachine.handle(.routeChanged))
    }

    public func applicationDidEnterBackground() {
        apply(stateMachine.handle(.appBackgrounded))
    }

    public func applicationWillEnterForeground() {
        _ = stateMachine.handle(.appForegrounded)
    }

    private func receive(samples: [Int16], timestamp: TimeInterval) {
        guard stateMachine.state == .capturing else { return }
        let chunks = chunker.append(samples: samples, timestamp: timestamp)
        for chunk in chunks {
            onLevel?(chunk.level)
            onChunk?(chunk)
        }
    }

    private func apply(_ actions: [AudioCaptureAction]) {
        for action in actions where action == .stopCapture {
            if let chunk = chunker.flush() {
                onLevel?(chunk.level)
                onChunk?(chunk)
            }
            microphone.stop()
            chunker.reset()
            onUtteranceEnd?()
        }
    }
}

#if os(iOS)
import AVFoundation

/// AVFoundation adapter.  It is created only by the iPhone app target; tests
/// inject a MicrophoneInputProviding fake and never touch the microphone.
public final class AVAudioMicrophoneInput: MicrophoneInputProviding {
    private let session: AVAudioSession
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    private func audioEngine() -> AVAudioEngine {
        if let engine { return engine }
        let created = AVAudioEngine()
        engine = created
        return created
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

    public func start(samples: @Sendable @escaping ([Int16], TimeInterval) -> Void) throws {
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = audioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.formatUnavailable
        }
        self.targetFormat = target
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, time in
            _ = time
            self?.convert(buffer: buffer, timestamp: ProcessInfo.processInfo.systemUptime, handler: samples)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        converter = nil
        targetFormat = nil
        try? session.setCategory(.soloAmbient, mode: .default, options: [])
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        timestamp: TimeInterval,
        handler: ([Int16], TimeInterval) -> Void
    ) {
        guard let converter, let targetFormat else { return }
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
        let values = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        handler(values, timestamp)
    }
}

public enum AudioCaptureError: Error, Equatable, Sendable {
    case formatUnavailable
}
#endif
