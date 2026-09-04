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
///
/// A stream the phone ends as an edit takes the other path: its words are an
/// instruction, never typed, and `editor` rewrites what is already in the field
/// to follow them.
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
        /// Runs beside `timer`, from the commit that ended the speech, so the
        /// whole wait can join a distribution rather than only a label.
        var clock: LatencyClock?
        var idleTimer: DispatchWorkItem?
        /// The phone said the finger is hovering an edit target. Nothing is
        /// typed while this is true and the hold has not ended.
        var editHinted = false
        var ended = false
        /// Decided by the end frame: these words are an instruction.
        var isEdit = false
        var holdTimer: DispatchWorkItem?

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
    private let editor: TranscriptEditing?
    private let focusedText: FocusedTextReading?
    private let vocabulary: SpokenVocabularySink?
    private let isSecureInputActive: @Sendable () -> Bool
    private let idleTimeout: TimeInterval
    private let latency: LatencyTracker?
    /// How long a hinted utterance waits for the release to say what it is,
    /// after its text is already in. Past this the release is assumed lost and
    /// the words are typed the ordinary way.
    private let editHintHoldTime: TimeInterval
    private var utterances: [Utterance] = []
    private var lastCommittedStream: SessionID?
    private var current = VoicePTTState()
    private var outcome: VoicePTTPhase = .idle
    private var outcomeGeneration = 0

    public init(
        sessions: TranscriptionSessionFactory,
        insertionSink: SafeTranscriptInsertionSink,
        normalizer: TranscriptNormalizer? = nil,
        editor: TranscriptEditing? = nil,
        focusedText: FocusedTextReading? = nil,
        vocabulary: SpokenVocabularySink? = nil,
        idleTimeout: TimeInterval = 1.5,
        editHintHoldTime: TimeInterval = 3,
        isSecureInputActive: @escaping @Sendable () -> Bool = SecureInput.isActive,
        latency: LatencyTracker? = nil
    ) {
        self.sessions = sessions
        self.insertionSink = insertionSink
        self.normalizer = normalizer
        self.editor = editor
        self.focusedText = focusedText
        self.vocabulary = vocabulary
        self.idleTimeout = idleTimeout
        self.editHintHoldTime = editHintHoldTime
        self.isSecureInputActive = isSecureInputActive
        self.latency = latency
    }

    public func receive(_ frame: VoiceStreamFrame) {
        queue.async { self.handle(frame) }
    }

    private func handle(_ frame: VoiceStreamFrame) {
        // Checked before the straggler guard: a cancel has to land even when a
        // silent pause already committed the utterance.
        if frame.isCancel {
            discard(frame.streamID)
            return
        }
        // Also before the straggler guard: a hint about a stream the idle
        // timeout already committed is exactly the case the hold exists for.
        if frame.isIntent {
            hint(frame.streamID, edit: frame.isEdit)
            return
        }
        // An end frame for a stream a silent pause already committed still gets
        // to say what its words were for.
        if frame.isEnd,
           let held = utterances.first(where: { $0.streamID == frame.streamID }),
           held.committed {
            end(held, isEdit: frame.isEdit)
            publish()
            return
        }
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
            end(utterance, isEdit: frame.isEdit)
        } else {
            armIdleTimer(utterance)
        }
        publish()
    }

    /// The hold is over, and the flag it ended with settles whether the words
    /// are text or an instruction.
    private func end(_ utterance: Utterance, isEdit: Bool) {
        utterance.ended = true
        utterance.isEdit = isEdit
        utterance.holdTimer?.cancel()
        utterance.holdTimer = nil
        commit(utterance)
        typeNextIfReady()
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
        utterance.clock = LatencyClock()
        utterance.session.commit()
    }

    /// The speaker threw this utterance away. Its recognizer is torn down, the
    /// preview goes, and nothing of it is typed. Later frames of the same
    /// stream are dropped as stragglers.
    private func discard(_ streamID: SessionID) {
        lastCommittedStream = streamID
        if let utterance = utterances.first(where: { $0.streamID == streamID }) {
            utterance.idleTimer?.cancel()
            utterance.idleTimer = nil
            utterance.holdTimer?.cancel()
            utterance.holdTimer = nil
            utterance.committed = true
            utterance.session.cancel()
            utterances.removeAll { $0 === utterance }
        }
        outcome = .idle
        outcomeGeneration += 1
        current.merge = "cancelled"
        publish()
        typeNextIfReady()
    }

    /// The phone is telling us where the finger is hovering. An edit hint holds
    /// the typing and starts loading the editor; clearing it lets go again.
    private func hint(_ streamID: SessionID, edit: Bool) {
        if edit { editor?.warmUp() }
        guard let utterance = utterances.first(where: { $0.streamID == streamID }) else { return }
        utterance.editHinted = edit
        if !edit {
            utterance.holdTimer?.cancel()
            utterance.holdTimer = nil
            typeNextIfReady()
        }
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
        // The finger is over an edit target and still down, so what these words
        // are for is not settled yet.
        if utterance.editHinted, !utterance.ended {
            armHoldTimer(utterance)
            return
        }
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
        guard !utterance.isEdit else {
            applyEdit(instruction: text, for: utterance)
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

    private func armHoldTimer(_ utterance: Utterance) {
        guard utterance.holdTimer == nil else { return }
        let timer = DispatchWorkItem {
            utterance.holdTimer = nil
            utterance.editHinted = false
            self.typeNextIfReady()
        }
        utterance.holdTimer = timer
        queue.asyncAfter(deadline: .now() + editHintHoldTime, execute: timer)
    }

    /// The spoken words are an instruction, so they are never typed. The field
    /// is the thing being edited: it goes to the editor with the instruction and
    /// comes back rewritten. Anything that goes wrong leaves the field alone.
    private func applyEdit(instruction: String, for utterance: Utterance) {
        guard let editor else {
            current.merge = "edit:noEditor"
            complete(utterance, phase: .failed)
            return
        }
        readFocusedField { [weak self] field in
            guard let self else { return }
            utterance.timer?.mark("read")
            guard case let .text(document) = field,
                  !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.current.merge = "edit:" + field.label
                self.complete(utterance, phase: .failed)
                return
            }
            guard document.count <= QwenTranscriptEditor.maximumDocumentCharacters else {
                self.current.merge = "edit:tooLong"
                self.complete(utterance, phase: .failed)
                return
            }
            editor.edit(document: document, instruction: instruction) { result in
                self.queue.async {
                    utterance.timer?.mark("edit")
                    switch result {
                    case let .success(edited) where edited != document:
                        self.replace(document, with: edited, for: utterance)
                    case .success:
                        self.current.merge = "edit:noChange"
                        self.complete(utterance, phase: .idle)
                    case .failure:
                        self.current.merge = "edit:failed"
                        self.complete(utterance, phase: .failed)
                    }
                }
            }
        }
    }

    /// The field is read again because the edit took seconds; if it moved in
    /// the meantime the rewrite is dropped rather than typed over new work.
    private func replace(_ document: String, with edited: String, for utterance: Utterance) {
        guard !isSecureInputActive() else {
            current.merge = "edit:secureInput"
            complete(utterance, phase: .failed)
            return
        }
        readFocusedField { [weak self] fresh in
            guard let self else { return }
            utterance.timer?.mark("recheck")
            guard fresh == .text(document) else {
                self.current.merge = "edit:fieldMoved"
                self.complete(utterance, phase: .failed)
                return
            }
            DispatchQueue.main.async {
                let typed = self.insertionSink.replaceAll(with: edited)
                self.queue.async {
                    utterance.timer?.mark("type")
                    self.current.merge = "edited"
                    self.complete(utterance, phase: typed ? .typed : .failed, text: edited)
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
        utterance.holdTimer?.cancel()
        utterance.holdTimer = nil
        utterances.removeAll { $0 === utterance }
        outcome = phase
        outcomeGeneration += 1
        let generation = outcomeGeneration
        if let text { current.lastFinalText = text }
        if let timer = utterance.timer { current.timing = timer.label }
        if let clock = utterance.clock {
            // An utterance with nothing to type never reached the field, so it
            // is neither a timing nor a refusal.
            switch phase {
            case .typed: latency?.record(microseconds: clock.elapsedMicroseconds)
            case .failed: latency?.recordRefusal()
            default: break
            }
        }
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
