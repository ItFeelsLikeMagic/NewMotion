import Foundation

/// What the phone-side recogniser can do right now.  The Settings row reads
/// this so a press never fails silently.
public enum OnDeviceVoiceReadiness: Equatable, Sendable {
    case ready
    /// The language model is still coming down from Apple.
    case downloading
    /// This OS or locale has no on-device transcriber.
    case unsupported

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .downloading: "Downloading the language model"
        case .unsupported: "Not available on this iPhone"
        }
    }
}

/// Splits the free-text Settings field into boost phrases.  Kept platform-free
/// so it can be tested without a microphone.
public enum VoiceBoostWords {
    public static let maximumPhrases = 100

    /// The hand-typed list wins on order, because it is the one the owner
    /// chose deliberately; the Mac's screen words fill the rest of the budget.
    /// Case-insensitive, so a name typed once is not boosted twice.
    public static func merge(typed: [String], fromMac: [String]) -> [String] {
        var seen = Set(typed.map { $0.lowercased() })
        var merged = typed
        for phrase in fromMac where !seen.contains(phrase.lowercased()) {
            guard merged.count < maximumPhrases else { break }
            seen.insert(phrase.lowercased())
            merged.append(phrase)
        }
        return merged
    }

    public static func parse(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, phrase in
                guard unique.count < maximumPhrases,
                      !unique.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) else { return }
                unique.append(phrase)
            }
    }
}

/// Splits a finished utterance into pieces the wire will actually carry.
///
/// `ProtocolBytes` caps a field at 2048 bytes, but the payload is serialised
/// as a JSON array of byte numbers, two to four characters each, inside an
/// 8192-byte envelope. So the real ceiling is far below the field cap, and the
/// keyboard chunker's 4096-byte default has always been over it. A dictated
/// sentence is nowhere near either bound; a five-minute monologue is, and it
/// should arrive in order rather than be dropped whole.
public enum SpokenTextChunker {
    /// Chosen so the worst case, four characters per byte, still clears the
    /// envelope with room for the rest of the JSON.
    public static let maximumPieceUTF8Bytes = 1_024

    public static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.utf8.count > maximumPieceUTF8Bytes else { return [trimmed] }

        var pieces: [String] = []
        var current = ""
        var bytes = 0
        // Iterating Characters keeps grapheme clusters whole, so a piece never
        // splits an emoji or a combining mark down the middle.
        for character in trimmed {
            let size = String(character).utf8.count
            if bytes + size > maximumPieceUTF8Bytes, !current.isEmpty {
                pieces.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// Turns push-to-talk audio into text on the phone, using Apple's on-device
/// analyser, so the words never travel as audio and the Mac needs neither the
/// `nemo-speech` server nor Ollama.  The Mac receives the finished sentence on
/// the ordinary keyboard path.
///
/// This facade is available on every OS the app runs on and simply reports
/// `.unsupported` below iOS 26, where Apple's analyser does not exist.  It sits
/// beside `VoiceUplink` rather than replacing it: one Settings toggle picks
/// which of the two handles an utterance, so the pair can be compared on the
/// same voice.
public final class OnDeviceVoice: @unchecked Sendable {
    /// Final text for an utterance that ended normally.
    public var onText: (@Sendable (String) -> Void)?
    /// Rough text while the finger is still down, for the on-screen preview.
    public var onPartialText: (@Sendable (String) -> Void)?
    /// Readiness changed; the Settings row follows it.
    public var onReadiness: (@Sendable (OnDeviceVoiceReadiness) -> Void)?

    /// An `AppleSpeechEngine` on iOS 26 and later, nil below it.
    private let engine: Any?

    public init(locale: Locale = .current) {
#if os(iOS)
        if #available(iOS 26.0, *) {
            engine = AppleSpeechEngine(locale: locale)
        } else {
            engine = nil
        }
#else
        engine = nil
#endif
    }

    public var isSupported: Bool { engine != nil }

    /// Resolves the audio format and pulls the language model down if it is not
    /// installed yet.  Called well before any press, so `begin` costs nothing
    /// but object creation.
    public func prepare() {
#if os(iOS)
        if #available(iOS 26.0, *), let engine = engine as? AppleSpeechEngine {
            engine.onText = { [weak self] in self?.onText?($0) }
            engine.onPartialText = { [weak self] in self?.onPartialText?($0) }
            engine.onReadiness = { [weak self] in self?.onReadiness?($0) }
            engine.prepare()
            return
        }
#endif
        onReadiness?(.unsupported)
    }

    /// Opens a recogniser for one utterance.  `boostWords` are the phrases the
    /// recogniser should lean towards, the same idea as the Nemotron speech
    /// context list.
    public func begin(boostWords: [String]) {
#if os(iOS)
        if #available(iOS 26.0, *), let engine = engine as? AppleSpeechEngine {
            engine.begin(boostWords: boostWords)
        }
#endif
    }

    /// One 16 kHz mono chunk from the capture controller.
    public func append(_ samples: [Int16]) {
#if os(iOS)
        if #available(iOS 26.0, *), let engine = engine as? AppleSpeechEngine {
            engine.append(samples)
        }
#endif
    }

    /// The finger lifted.  Closes the input and lets the recogniser settle; the
    /// finished text arrives on `onText`.
    public func end() {
#if os(iOS)
        if #available(iOS 26.0, *), let engine = engine as? AppleSpeechEngine {
            engine.end()
        }
#endif
    }

    /// The utterance was thrown away.  Nothing is delivered.
    public func cancel() {
#if os(iOS)
        if #available(iOS 26.0, *), let engine = engine as? AppleSpeechEngine {
            engine.cancel()
        }
#endif
    }
}

#if os(iOS)
import AVFoundation
import Speech

/// The iOS 26 analyser itself.  Only `OnDeviceVoice` touches it.
@available(iOS 26.0, *)
final class AppleSpeechEngine: @unchecked Sendable {
    /// The chunker upstream emits 16 kHz mono Int16, which is also what the
    /// Nemotron path puts on the wire.
    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    var onText: (@Sendable (String) -> Void)?
    var onPartialText: (@Sendable (String) -> Void)?
    var onReadiness: (@Sendable (OnDeviceVoiceReadiness) -> Void)?

    private let locale: Locale
    /// `append` runs on the voice queue while the session tasks run on the
    /// concurrent pool, so every field below is taken under this lock.
    private let lock = NSLock()

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var cancelled = false

    init(locale: Locale) {
        self.locale = locale
    }

    func prepare() {
        Task { [weak self] in
            guard let self else { return }
            guard SpeechTranscriber.isAvailable,
                  await SpeechTranscriber.supportedLocale(equivalentTo: self.locale) != nil else {
                self.onReadiness?(.unsupported)
                return
            }
            let probe = self.makeTranscriber()
            if await AssetInventory.status(forModules: [probe]) != .installed {
                self.onReadiness?(.downloading)
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                        try await request.downloadAndInstall()
                    }
                } catch {
                    IPhoneDebugLog.emit("ondevice_asset_failed", ["err": "\(type(of: error))"])
                    self.onReadiness?(.unsupported)
                    return
                }
            }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
            self.store(analyzerFormat: format)
            self.onReadiness?(.ready)
        }
    }

    func begin(boostWords: [String]) {
        let transcriber = makeTranscriber()
        let context = AnalysisContext()
        if !boostWords.isEmpty {
            context.contextualStrings = [.general: boostWords]
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [transcriber],
            analysisContext: context
        )

        lock.lock()
        self.continuation?.finish()
        resultsTask?.cancel()
        cancelled = false
        self.continuation = continuation
        self.analyzer = analyzer
        converter = nil
        lock.unlock()

        resultsTask = Task { [weak self] in
            var finalized = AttributedString()
            do {
                for try await result in transcriber.results {
                    if result.isFinal {
                        finalized += result.text
                    } else {
                        self?.onPartialText?(String((finalized + result.text).characters))
                    }
                }
            } catch {
                IPhoneDebugLog.emit("ondevice_failed", ["err": "\(type(of: error))"])
                return
            }
            guard let self, !self.isCancelled else { return }
            let text = String(finalized.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            IPhoneDebugLog.emit("ondevice_final", ["chars": "\(text.count)"])
            guard !text.isEmpty else { return }
            self.onText?(text)
        }
    }

    /// Called on the voice queue: converts and hands off, never waits.
    func append(_ samples: [Int16]) {
        guard let captured = Self.buffer(from: samples) else { return }
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        var input = captured
        if let target = analyzerFormat, target != Self.captureFormat {
            if converter == nil {
                converter = AVAudioConverter(from: Self.captureFormat, to: target)
            }
            guard let converter, let converted = Self.convert(captured, with: converter, to: target) else {
                lock.unlock()
                return
            }
            input = converted
        }
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: input))
    }

    func end() {
        lock.lock()
        let continuation = self.continuation
        let analyzer = self.analyzer
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        let analyzer = self.analyzer
        self.continuation = nil
        self.analyzer = nil
        lock.unlock()
        continuation?.finish()
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// `NSLock` may not be taken from an async context, so the two fields the
    /// session tasks touch are reached through these synchronous accessors.
    private func store(analyzerFormat format: AVAudioFormat?) {
        lock.lock()
        analyzerFormat = format
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func buffer(from samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: captureFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.int16ChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 1))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
#endif
