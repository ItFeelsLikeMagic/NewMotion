import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

public enum VoicePTTPhase: String, Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case typed
    case failed
}

/// Live PTT stream: ASR starts on the first frame, S1+type run on close.
/// Transcript text is never stored on the debug snapshot.
public final class VoicePTTCoordinator: @unchecked Sendable {
    public private(set) var phase: VoicePTTPhase = .idle
    public private(set) var receivedFrames: UInt64 = 0
    public private(set) var receivedSamples: UInt64 = 0
    public var health: AudioHealthSnapshot {
        AudioHealthSnapshot(
            receivedChunks: receivedFrames,
            receivedSamples: receivedSamples,
            missingChunks: 0,
            missingSamples: 0,
            duplicateChunks: 0,
            lateChunks: 0,
            durationSeconds: Double(receivedSamples) / 16_000.0,
            lastLevel: 0
        )
    }
    public var onPhaseChange: (@Sendable (VoicePTTPhase) -> Void)?

    private let streaming: StreamingSpeechProviding
    private let insertionSink: SafeTranscriptInsertionSink
    private var currentStream: SessionID?

    public init(
        streaming: StreamingSpeechProviding,
        insertionSink: SafeTranscriptInsertionSink
    ) {
        self.streaming = streaming
        self.insertionSink = insertionSink
    }

    public func receive(_ frame: VoiceStreamFrame) {
        if currentStream == nil || currentStream != frame.streamID {
            if phase == .listening || phase == .transcribing {
                streaming.cancelUtterance()
            }
            currentStream = frame.streamID
            receivedFrames = 0
            receivedSamples = 0
            streaming.beginUtterance()
            setPhase(.listening)
        }

        if frame.sampleCount > 0, !frame.payload.isEmpty {
            let samples = IMAADPCM.decode(payload: frame.payload, sampleCount: Int(frame.sampleCount))
            if !samples.isEmpty {
                streaming.appendPCM16(samples)
                receivedSamples += UInt64(samples.count)
            }
        }
        receivedFrames += 1

        if frame.isEnd {
            finishListening()
        }
    }

    public func disconnect() {
        if phase == .listening || phase == .transcribing {
            streaming.cancelUtterance()
        }
        currentStream = nil
        setPhase(.idle)
    }

    public func finishNow() {
        finishListening()
    }

    private func finishListening() {
        guard phase == .listening else { return }
        currentStream = nil
        setPhase(.transcribing)
        streaming.endUtterance { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.setPhase(.idle)
                    return
                }
                if self.insertionSink.insertTranscript(trimmed) {
                    self.setPhase(.typed)
                } else {
                    self.setPhase(.failed)
                }
            case .failure:
                self.setPhase(.failed)
            }
        }
    }

    private func setPhase(_ phase: VoicePTTPhase) {
        self.phase = phase
        onPhaseChange?(phase)
    }
}
