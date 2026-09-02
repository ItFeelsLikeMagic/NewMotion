import Foundation

/// Parses one helper stdout line. The helper never logs transcripts.
public enum TranscriptHelperLine {
    public static func parse(_ line: String) -> Result<String, SpeechTranscriptionError>? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "READY" || trimmed == "PONG" || trimmed.isEmpty {
            return nil
        }
        if trimmed == "ERR" {
            return .failure(.failed)
        }
        if trimmed.hasPrefix("OK ") {
            return .success(String(trimmed.dropFirst(3)))
        }
        if trimmed == "OK" {
            return .success("")
        }
        return .failure(.failed)
    }
}

/// Runs the local Nemotron + S1-mini helper as a kept-alive process.
public final class NemotronSpeechTranscriptionProvider: SpeechTranscriptionProviding, StreamingSpeechProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private let queue = DispatchQueue(label: "phoneremote.nemotron")
    private let pythonURL: URL
    private let scriptURL: URL

    public init?(pythonURL: URL? = nil, scriptURL: URL? = nil) {
        let python = pythonURL ?? Self.defaultPythonURL()
        let script = scriptURL ?? Self.defaultScriptURL()
        guard FileManager.default.isExecutableFile(atPath: python.path) || FileManager.default.fileExists(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            return nil
        }
        self.pythonURL = python
        self.scriptURL = script
    }

    public func requestAuthorization(completion: @escaping @Sendable (SpeechAuthorizationState) -> Void) {
        completion(.authorized)
    }

    public func prepare() {
        queue.async {
            self.lock.lock()
            _ = self.ensureProcessLocked()
            self.lock.unlock()
        }
    }

    public func beginUtterance() {
        queue.sync {
            lock.lock()
            _ = ensureProcessLocked()
            _ = writeLineLocked("STREAM")
            lock.unlock()
        }
    }

    public func appendPCM16(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        let line = "PCM " + data.base64EncodedString()
        queue.sync {
            lock.lock()
            _ = writeLineLocked(line)
            lock.unlock()
        }
    }

    public func endUtterance(completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void) {
        queue.async {
            self.lock.lock()
            _ = self.writeLineLocked("END")
            let line = self.readReplyLocked(timeout: 60)
            self.lock.unlock()
            let parsed = line.flatMap(TranscriptHelperLine.parse) ?? .failure(.failed)
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    public func cancelUtterance() {
        queue.sync {
            lock.lock()
            _ = writeLineLocked("CANCEL")
            lock.unlock()
        }
    }

    public func transcribeWAV(at url: URL, completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void) {
        queue.async {
            let result = self.transcribeSync(url: url)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func transcribeSync(url: URL) -> Result<String, SpeechTranscriptionError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.invalidAudioURL)
        }
        lock.lock()
        defer { lock.unlock() }
        guard ensureProcessLocked() else {
            return .failure(.recognizerUnavailable)
        }
        guard let stdinHandle, let stdoutHandle else {
            return .failure(.recognizerUnavailable)
        }
        do {
            try stdinHandle.write(contentsOf: Data((url.path + "\n").utf8))
        } catch {
            tearDownLocked()
            return .failure(.failed)
        }
        guard let line = readLineLocked(from: stdoutHandle, timeout: 60) else {
            tearDownLocked()
            return .failure(.failed)
        }
        return TranscriptHelperLine.parse(line) ?? .failure(.failed)
    }

    @discardableResult
    private func writeLineLocked(_ line: String) -> Bool {
        guard let stdinHandle else { return false }
        do {
            try stdinHandle.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            tearDownLocked()
            return false
        }
    }

    private func readReplyLocked(timeout: TimeInterval) -> String? {
        guard let stdoutHandle else { return nil }
        return readLineLocked(from: stdoutHandle, timeout: timeout)
    }

    @discardableResult
    private func ensureProcessLocked() -> Bool {
        if let process, process.isRunning { return true }
        tearDownLocked()

        let process = Process()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sttRoot = ProcessInfo.processInfo.environment["PHONE_REMOTE_STT_ROOT"] ?? "\(home)/stt-tts-agent"
        let uv = URL(fileURLWithPath: "\(home)/.local/bin/uv")
        if FileManager.default.isExecutableFile(atPath: uv.path) {
            process.executableURL = uv
            process.arguments = [
                "run", "--project", sttRoot, "--with", "websocket-client",
                "python", scriptURL.path, "--serve", "--language", "en-US"
            ]
        } else {
            process.executableURL = pythonURL
            process.arguments = [scriptURL.path, "--serve", "--language", "en-US"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home)/.local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["PHONE_REMOTE_STT_ROOT"] = sttRoot
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return false
        }

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = try? handle.read(upToCount: 4096)
        }

        guard let stdoutHandle,
              let line = readLineLocked(from: stdoutHandle, timeout: 30),
              line.trimmingCharacters(in: .whitespacesAndNewlines) == "READY" else {
            tearDownLocked()
            return false
        }
        return true
    }

    private func readLineLocked(from handle: FileHandle, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let byte: Data
            do {
                byte = try handle.read(upToCount: 1) ?? Data()
            } catch {
                return nil
            }
            if byte.isEmpty {
                if let process, !process.isRunning {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            if byte[0] == 10 {
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(byte)
            if buffer.count > 8_192 {
                return nil
            }
        }
        return nil
    }

    private func tearDownLocked() {
        stdinHandle = nil
        stdoutHandle = nil
        if let process {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
    }

    deinit {
        lock.lock()
        tearDownLocked()
        lock.unlock()
    }

    public static func defaultPythonURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PHONE_REMOTE_STT_PYTHON"] {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("stt-tts-agent/.venv/bin/python")
    }

    public static func defaultScriptURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PHONE_REMOTE_TRANSCRIBE"] {
            return URL(fileURLWithPath: override)
        }
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/transcribe-ptt.py")
        if FileManager.default.fileExists(atPath: fromSource.path) {
            return fromSource
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ChatGPT/potato-eater/scripts/transcribe-ptt.py")
    }
}
