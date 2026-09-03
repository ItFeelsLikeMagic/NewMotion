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

/// Counts for the newest utterance. Safe for logs and the debug snapshot.
public struct AudioHealthSnapshot: Equatable, Sendable {
    public var receivedFrames: UInt64 = 0
    public var receivedSamples: UInt64 = 0
    public var missingChunks: UInt64 = 0
    public var durationSeconds: Double { Double(receivedSamples) / 16_000 }

    public init() {}
}

/// UI state. `preview` and `lastFinalText` are for display only and must
/// never be logged or written to the debug snapshot.
public struct VoicePTTState: Equatable, Sendable {
    public var phase: VoicePTTPhase = .idle
    public var health = AudioHealthSnapshot()
    /// Which path the last utterance took into the field: `merged`, `appended`,
    /// or the reason the field could not be joined. A label, never field text.
    public var merge = "none"
    /// How long each stage of the newest utterance took, from the commit that
    /// ended the speech to the text landing in the field. Durations only.
    public var timing = "none"
    public var preview = ""
    public var lastFinalText: String?

    public init() {}
}

/// One transcription session per PTT stream. Audio is forwarded frame by
/// frame; `.end` (or 1.5 s without frames) commits. Overlapping utterances
/// each transcribe on their own; typed output stays in start order. A final
/// passes through `normalizer`, when one is set, before it is typed, together
/// with whatever `focusedText` finds already in the field so that repeated
/// presses read as one piece of writing.
public final class VoicePTTCoordinator: @unchecked Sendable {
    /// Wall-clock time between the stages of one utterance, starting at commit.
    private final class StageTimer {
        private var last = DispatchTime.now()
        private var stages: [(name: String, ms: Double)] = []

        func mark(_ name: String) {
            let now = DispatchTime.now()
            let ms = Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000
            stages.append((name, ms))
            last = now
        }

        var label: String {
            let total = stages.reduce(0) { $0 + $1.ms }
            let parts = stages.map { "\($0.name) \(Int($0.ms.rounded()))" }
            return parts.joined(separator: "/") + " = \(Int(total.rounded()))ms"
        }
    }

    /// Mutated only on the coordinator queue; the main-thread hop just carries it back.
    private final class Utterance: @unchecked Sendable {
        let streamID: SessionID
        let session: TranscriptionSession
        var health = AudioHealthSnapshot()
        var nextSequence: UInt32
        var preview = ""
        var committed = false
        var result: Result<String, TranscriptionError>?
        var typing = false
        var timer: StageTimer?
        var idleTimer: DispatchWorkItem?

        init(streamID: SessionID, session: TranscriptionSession, nextSequence: UInt32) {
            self.streamID = streamID
            self.session = session
            self.nextSequence = nextSequence
        }
    }

    private static let outcomeDisplayTime: TimeInterval = 2

    public var onStateChange: (@Sendable (VoicePTTState) -> Void)?
    public var state: VoicePTTState { queue.sync { current } }

    private let queue = DispatchQueue(label: "phoneremote.voice-ptt")
    private let sessions: TranscriptionSessionFactory
    private let insertionSink: SafeTranscriptInsertionSink
    private let normalizer: TranscriptNormalizer?
    private let focusedText: FocusedTextReading?
    private let vocabulary: SpokenVocabularySink?
    private let isSecureInputActive: @Sendable () -> Bool
    private let idleTimeout: TimeInterval
    private var utterances: [Utterance] = []
    private var lastCommittedStream: SessionID?
    private var current = VoicePTTState()
    private var outcome: VoicePTTPhase = .idle
    private var outcomeGeneration = 0

    public init(
        sessions: TranscriptionSessionFactory,
        insertionSink: SafeTranscriptInsertionSink,
        normalizer: TranscriptNormalizer? = nil,
        focusedText: FocusedTextReading? = nil,
        vocabulary: SpokenVocabularySink? = nil,
        idleTimeout: TimeInterval = 1.5,
        isSecureInputActive: @escaping @Sendable () -> Bool = SecureInput.isActive
    ) {
        self.sessions = sessions
        self.insertionSink = insertionSink
        self.normalizer = normalizer
        self.focusedText = focusedText
        self.vocabulary = vocabulary
        self.idleTimeout = idleTimeout
        self.isSecureInputActive = isSecureInputActive
    }

    public func receive(_ frame: VoiceStreamFrame) {
        queue.async { self.handle(frame) }
    }

    private func handle(_ frame: VoiceStreamFrame) {
        // Frames that straggle in after the idle timeout committed their stream are dropped.
        guard frame.streamID != lastCommittedStream else { return }
        let utterance = utterances.last { $0.streamID == frame.streamID } ?? begin(frame)
        if frame.sequence > utterance.nextSequence {
            utterance.health.missingChunks += UInt64(frame.sequence - utterance.nextSequence)
        }
        utterance.nextSequence = max(utterance.nextSequence, frame.sequence &+ 1)
        utterance.health.receivedFrames += 1
        if frame.sampleCount > 0, !frame.payload.isEmpty {
            let samples = IMAADPCM.decode(payload: frame.payload, sampleCount: Int(frame.sampleCount))
            utterance.health.receivedSamples += UInt64(samples.count)
            utterance.session.send(pcm16: samples)
        }
        current.health = utterance.health
        if frame.isEnd {
            commit(utterance)
        } else {
            armIdleTimer(utterance)
        }
        publish()
    }

    private func begin(_ frame: VoiceStreamFrame) -> Utterance {
        let streamID = frame.streamID
        let session = sessions.makeSession(handlers: TranscriptionSessionHandlers(
            onDelta: { [weak self] delta in
                self?.queue.async { self?.appendDelta(delta, to: streamID) }
            },
            onResult: { [weak self] result in
                self?.queue.async { self?.finish(streamID, with: result) }
            }
        ))
        // Asking now gives a field that needs waking the length of the sentence
        // to become readable, rather than being asked once it is too late.
        if let focusedText { DispatchQueue.main.async { focusedText.prepare() } }
        let utterance = Utterance(streamID: streamID, session: session, nextSequence: frame.sequence &+ 1)
        if !frame.isStart {
            // Sequence 0 is the start frame, so everything before this frame was lost.
            utterance.health.missingChunks = UInt64(max(frame.sequence, 1) - 1)
        }
        utterances.append(utterance)
        return utterance
    }

    private func armIdleTimer(_ utterance: Utterance) {
        utterance.idleTimer?.cancel()
        let timer = DispatchWorkItem {
            self.commit(utterance)
            self.publish()
        }
        utterance.idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: timer)
    }

    private func commit(_ utterance: Utterance) {
        guard !utterance.committed else { return }
        utterance.committed = true
        utterance.idleTimer?.cancel()
        utterance.idleTimer = nil
        lastCommittedStream = utterance.streamID
        utterance.timer = StageTimer()
        utterance.session.commit()
    }

    private func appendDelta(_ delta: String, to streamID: SessionID) {
        guard let utterance = utterances.last(where: { $0.streamID == streamID }) else { return }
        utterance.preview += delta
        publish()
    }

    private func finish(_ streamID: SessionID, with result: Result<String, TranscriptionError>) {
        guard let utterance = utterances.first(where: { $0.streamID == streamID }) else { return }
        utterance.timer?.mark("asr")
        utterance.result = result
        typeNextIfReady()
    }

    /// Types the oldest utterance once its final text is in. Later finals wait
    /// here until it has been typed or has failed.
    private func typeNextIfReady() {
        guard let utterance = utterances.first, let result = utterance.result, !utterance.typing else { return }
        utterance.typing = true
        guard case let .success(raw) = result else {
            complete(utterance, phase: .failed)
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            complete(utterance, phase: .idle)
            return
        }
        // Saying a word is what earns it a long life in the boost list. This is
        // the recogniser's own words, before the normalizer rewrites them.
        vocabulary?.heard(text)
        guard let normalizer else {
            type(text, for: utterance)
            return
        }
        // The words already in the field travel with the new ones, so the
        // normalizer punctuates and spaces the join instead of treating every
        // press as the start of a sentence.
        readFocusedField { [weak self] field in
            guard let self else { return }
            utterance.timer?.mark("read")
            let existing = if case let .text(value) = field { value } else { "" }
            normalizer.normalize(TranscriptMerge.payload(existing: existing, transcript: text)) { normalized in
                self.queue.async {
                    utterance.timer?.mark("norm")
                    self.apply(
                        normalized.trimmingCharacters(in: .whitespacesAndNewlines),
                        over: field,
                        spoken: text,
                        for: utterance
                    )
                }
            }
        }
    }

    /// Applies the normalized whole as an edit against the field. The field is
    /// read again because normalizing took time; if it moved, or if the rewrite
    /// would rewind further than the budget allows, only the new words go in.
    private func apply(_ merged: String, over field: FocusedText, spoken: String, for utterance: Utterance) {
        guard case let .text(existing) = field, !existing.isEmpty else {
            current.merge = field.label
            type(merged, for: utterance)
            return
        }
        guard !merged.isEmpty else {
            current.merge = "merged"
            complete(utterance, phase: .idle)
            return
        }
        readFocusedField { [weak self] fresh in
            guard let self else { return }
            utterance.timer?.mark("recheck")
            guard fresh == .text(existing),
                  let edit = TranscriptMerge.edit(from: existing, to: merged) else {
                self.current.merge = "appended"
                self.type(TranscriptMerge.tail(existing: existing, transcript: spoken), for: utterance)
                return
            }
            self.current.merge = "merged"
            self.type(edit.insertion, deleting: edit.deletions, for: utterance)
        }
    }

    /// Accessibility walks the live UI tree, so the read happens on the main
    /// thread the way the typing does. The caller resumes on the queue.
    private func readFocusedField(_ completion: @escaping @Sendable (FocusedText) -> Void) {
        guard let focusedText else {
            completion(.unavailable("noReader"))
            return
        }
        DispatchQueue.main.async {
            let field = focusedText.focusedText()
            self.queue.async { completion(field) }
        }
    }

    /// Normalizing filler-only speech correctly yields nothing to type.
    private func type(_ text: String, deleting deletions: Int = 0, for utterance: Utterance) {
        guard !text.isEmpty || deletions > 0 else {
            complete(utterance, phase: .idle)
            return
        }
        guard !isSecureInputActive() else {
            complete(utterance, phase: .failed)
            return
        }
        DispatchQueue.main.async {
            var typed = deletions == 0 || self.insertionSink.deleteBackward(deletions)
            if typed, !text.isEmpty {
                typed = self.insertionSink.insertTranscript(text)
            }
            self.queue.async {
                utterance.timer?.mark("type")
                self.complete(utterance, phase: typed ? .typed : .failed, text: text)
            }
        }
    }

    private func complete(_ utterance: Utterance, phase: VoicePTTPhase, text: String? = nil) {
        utterances.removeAll { $0 === utterance }
        outcome = phase
        outcomeGeneration += 1
        let generation = outcomeGeneration
        if let text { current.lastFinalText = text }
        if let timer = utterance.timer { current.timing = timer.label }
        publish()
        typeNextIfReady()
        queue.asyncAfter(deadline: .now() + Self.outcomeDisplayTime) {
            guard generation == self.outcomeGeneration else { return }
            self.outcome = .idle
            self.publish()
        }
    }

    private func publish() {
        if utterances.contains(where: { !$0.committed }) {
            current.phase = .listening
        } else if !utterances.isEmpty {
            current.phase = .transcribing
        } else {
            current.phase = outcome
        }
        current.preview = utterances.last?.preview ?? ""
        onStateChange?(current)
    }
}
