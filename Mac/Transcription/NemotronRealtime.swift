import Foundation

/// Owns the local `nemo-speech serve` process and hands out one WebSocket
/// session per utterance. Everything runs on its own queue; nothing here
/// touches the main thread.
public final class NemotronServer: TranscriptionSessionFactory, @unchecked Sendable {
    public static let defaultPort = 18766
    public static let logURL = URL(fileURLWithPath: "/tmp/phoneremote-nemo-speech.log")

    private let queue = DispatchQueue(label: "phoneremote.nemotron.server")
    private let port: Int
    private let speechContext: SpeechContextProviding?
    private let http = URLSession(configuration: .ephemeral)
    private var process: Process?
    private var ready = false
    private var polling = false
    private var waiters: [(deadline: Date, body: @Sendable (Bool) -> Void)] = []

    public init(port: Int? = nil, speechContext: SpeechContextProviding? = nil) {
        self.port = port
            ?? ProcessInfo.processInfo.environment["PHONE_REMOTE_NEMO_PORT"].flatMap(Int.init)
            ?? Self.defaultPort
        self.speechContext = speechContext
    }

    var realtimeURL: URL { URL(string: "ws://127.0.0.1:\(port)/v1/realtime")! }

    /// Health-checks the port and spawns the server if nothing answers.
    public func start() {
        queue.async { self.pollIfNeeded() }
    }

    public func stop() {
        queue.sync {
            process?.terminate()
            process = nil
        }
    }

    public func makeSession(handlers: TranscriptionSessionHandlers) -> TranscriptionSession {
        NemotronRealtimeSession(
            url: realtimeURL,
            server: self,
            handlers: handlers,
            speechContext: speechContext
        )
    }

    /// Runs `body` on this server's queue with `true` once `/health` answers,
    /// or with `false` after `timeout`.
    func whenReady(timeout: TimeInterval, _ body: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            if self.ready {
                body(true)
                return
            }
            self.waiters.append((Date().addingTimeInterval(timeout), body))
            self.pollIfNeeded()
        }
    }

    /// A session could not reach the server; re-check and respawn if needed.
    func markUnavailable() {
        queue.async {
            self.ready = false
            self.pollIfNeeded()
        }
    }

    private func pollIfNeeded() {
        guard !polling else { return }
        polling = true
        poll()
    }

    private func poll() {
        checkHealth { healthy in
            self.queue.async {
                if healthy {
                    self.polling = false
                    self.ready = true
                    self.resolveWaiters(true)
                    return
                }
                if let process = self.process, !process.isRunning {
                    // Our child exited without becoming healthy; try again on the next request.
                    self.process = nil
                    self.polling = false
                    self.resolveWaiters(false)
                    return
                }
                if self.process == nil {
                    self.spawn()
                }
                let now = Date()
                let expired = self.waiters.filter { $0.deadline <= now }
                self.waiters.removeAll { $0.deadline <= now }
                expired.forEach { $0.body(false) }
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.poll() }
            }
        }
    }

    private func resolveWaiters(_ ready: Bool) {
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.body(ready) }
    }

    private func checkHealth(_ completion: @escaping @Sendable (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 1
        http.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    private func spawn() {
        guard let model = Self.modelURL() else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let process = Process()
        process.executableURL = home.appendingPathComponent(".local/bin/nemo-speech")
        process.arguments = [
            "serve",
            "--asr-model", model.path,
            "--device", "metal",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--no-ui",
            "--read-timeout", "120",
            "--write-timeout", "120"
        ]
        // The server logs model and listener status only, never transcripts.
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: Self.logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        guard (try? process.run()) != nil else { return }
        self.process = process
    }

    /// The Hugging Face hub snapshot of nvidia/nemotron-3.5-asr-streaming-0.6b.
    private static func modelURL() -> URL? {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--nvidia--nemotron-3.5-asr-streaming-0.6b")
        guard let commit = try? String(contentsOf: hub.appendingPathComponent("refs/main"), encoding: .utf8) else {
            return nil
        }
        let model = hub
            .appendingPathComponent("snapshots")
            .appendingPathComponent(commit.trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent("nemotron-3.5-asr-streaming-0.6b.q8_0.gguf")
        return FileManager.default.fileExists(atPath: model.path) ? model : nil
    }
}

/// One `/v1/realtime` WebSocket. Audio sent before the socket opens is queued
/// and flushed on open, so the caller never waits for the connection.
final class NemotronRealtimeSession: NSObject, TranscriptionSession, URLSessionWebSocketDelegate, @unchecked Sendable {
    private static let readyTimeout: TimeInterval = 40
    private static let resultTimeout: TimeInterval = 30
    /// How long the boost list may take to arrive. Past this the utterance
    /// goes out unbiased rather than holding on to the start of the sentence.
    private static let speechContextTimeout: TimeInterval = 0.3
    static let sampleRate = 16_000
    /// This recogniser applies one strength to the whole list and clamps it at
    /// five; three is the documented working value for its cache-aware RNNT
    /// head (`docs/asr/configuration.md`, word boosting).
    static let speechContextBoost = 3.0

    private let queue = DispatchQueue(label: "phoneremote.nemotron.session")
    private let url: URL
    private let server: NemotronServer
    private let handlers: TranscriptionSessionHandlers
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var pendingAudio: [Data] = []
    private var committed = false
    private var finished = false
    /// Nil until the boost list has been decided, one way or the other.
    private var phrases: [String]?
    private var configured = false

    init(
        url: URL,
        server: NemotronServer,
        handlers: TranscriptionSessionHandlers,
        speechContext: SpeechContextProviding? = nil
    ) {
        self.url = url
        self.server = server
        self.handlers = handlers
        super.init()
        if let speechContext {
            speechContext.speechContext { phrases in
                self.queue.async { self.adopt(phrases) }
            }
            queue.asyncAfter(deadline: .now() + Self.speechContextTimeout) { self.adopt([]) }
        } else {
            phrases = []
        }
        server.whenReady(timeout: Self.readyTimeout) { ready in
            self.queue.async {
                guard ready else {
                    self.finish(.failure(.serverUnavailable))
                    return
                }
                self.open()
            }
        }
    }

    func send(pcm16 samples: [Int16]) {
        // Apple platforms are little-endian, which is the wire format.
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        queue.async {
            if self.configured {
                self.task?.send(.data(data)) { _ in }
            } else {
                self.pendingAudio.append(data)
            }
        }
    }

    func commit() {
        queue.async {
            self.committed = true
            if self.configured { self.sendCommit() }
        }
    }

    func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.urlSession?.invalidateAndCancel()
        }
    }

    /// The first list to arrive wins; the timeout and the reader race and only
    /// one of them can decide the utterance.
    private func adopt(_ phrases: [String]) {
        guard self.phrases == nil else { return }
        self.phrases = phrases
        configureIfReady()
    }

    /// The server refuses a session update once audio has started, so the boost
    /// list and the buffered frames leave in that order or not at all.
    private func configureIfReady() {
        guard !finished, isOpen, !configured, let phrases, let task else { return }
        configured = true
        task.send(.string(Self.sessionUpdate(phrases: phrases))) { _ in }
        for data in pendingAudio {
            task.send(.data(data)) { _ in }
        }
        pendingAudio.removeAll()
        if committed { sendCommit() }
    }

    static func sessionUpdate(phrases: [String]) -> String {
        var session: [String: Any] = ["sample_rate": sampleRate]
        if !phrases.isEmpty {
            session["speech_contexts"] = [["phrases": phrases, "boost": speechContextBoost]]
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: ["type": "session.update", "session": session]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"type":"session.update","session":{"sample_rate":16000}}"#
        }
        return text
    }

    private func open() {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        urlSession = session
        self.task = task
        task.resume()
        receiveNext(task)
    }

    /// The streaming recognizer needs right context after the last word, and
    /// the phone stops the moment the finger lifts, so pad with silence first.
    private static let trailingSilence = Data(count: 16_000 * 2 * 4 / 10)

    private func sendCommit() {
        task?.send(.data(Self.trailingSilence)) { _ in }
        task?.send(.string(#"{"type":"input_audio_buffer.commit"}"#)) { _ in }
        queue.asyncAfter(deadline: .now() + Self.resultTimeout) {
            self.finish(.failure(.serverError))
        }
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            self.queue.async {
                guard !self.finished else { return }
                switch result {
                case .failure:
                    self.finish(.failure(.connectionFailed))
                case let .success(message):
                    if case let .string(text) = message, let event = RealtimeServerEvent.parse(text) {
                        self.handle(event)
                    }
                    if !self.finished { self.receiveNext(task) }
                }
            }
        }
    }

    private func handle(_ event: RealtimeServerEvent) {
        switch event {
        case let .delta(text):
            if !text.isEmpty { handlers.onDelta(text) }
        case let .completed(transcript):
            finish(.success(transcript))
        case .error:
            finish(.failure(.serverError))
        case .sessionCreated, .sessionUpdated, .committed, .cleared:
            break
        }
    }

    private func finish(_ result: Result<String, TranscriptionError>) {
        guard !finished else { return }
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        if result == .failure(.connectionFailed) { server.markUnavailable() }
        handlers.onResult(result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async {
            self.isOpen = true
            self.configureIfReady()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        queue.async { self.finish(.failure(.connectionFailed)) }
    }
}
