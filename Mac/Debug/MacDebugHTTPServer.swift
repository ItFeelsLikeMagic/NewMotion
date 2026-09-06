import Foundation
import Network

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Loopback-only debug HTTP server. Bind failures try the next few ports
/// instead of listening on every interface.
public final class MacDebugHTTPServer: @unchecked Sendable {
    public private(set) var port: UInt16?
    /// Answers `/focus`.  Runs on the main thread because it reads the live UI
    /// tree, and gives up rather than holding a connection open.
    public var focusProbe: (@Sendable () -> [String: String])?
    public var vocabularyProbe: (@Sendable (String?) -> [String: String])?
    /// Answers `/keyburst`.  Posts keys and reads the field, so it runs on the
    /// main thread like the typing does.
    public var keyBurstProbe: (@Sendable (Int) -> [String: String])?
    /// Fills the `latency` field of `/state`. Summarising sorts a window per
    /// stage, so it happens here, on a reader's connection, and never on the
    /// path being measured.
    public var latencyProbe: (@Sendable () -> [LatencySummary])?

    private let box: MacDebugSnapshotBox
    private let preferredPort: UInt16
    private let portFileURL: URL
    private let queue = DispatchQueue(label: "com.example.newmotion.macos.debug-server")
    private var listener: NWListener?
    private var startPort: UInt16 = 0

    public init(
        box: MacDebugSnapshotBox,
        preferredPort: UInt16 = MacDebugHTTP.defaultPort,
        portFileURL: URL = MacDebugHTTP.portFileURL
    ) {
        self.box = box
        self.preferredPort = preferredPort
        self.portFileURL = portFileURL
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startPort = self.preferredPort == 0 ? 0 : self.preferredPort
            self.listen(on: self.startPort)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            port = nil
            try? FileManager.default.removeItem(at: portFileURL)
        }
    }

    private func listen(on candidate: UInt16) {
        listener?.cancel()
        listener = nil
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: candidate) ?? .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let bound = listener.port?.rawValue ?? candidate
                    self.port = bound
                    self.writePortFile(port: bound)
                case .failed:
                    listener.cancel()
                    self.listener = nil
                    self.retry(after: candidate)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            retry(after: candidate)
        }
    }

    private func retry(after candidate: UInt16) {
        guard preferredPort != 0 else { return }
        let next = candidate &+ 1
        let last = preferredPort &+ 9
        guard next <= last, next != 0 else { return }
        listen(on: next)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let response = MacDebugHTTP.handle(
                request: request,
                snapshot: self.box.current(),
                focus: { self.probeFocus() },
                vocabulary: { self.probeVocabulary(app: $0) },
                keyBurst: { self.probeKeyBurst(count: $0) },
                latency: { self.latencyProbe?() ?? [] }
            )
            connection.send(content: response.httpData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static let probeTimeout: TimeInterval = 2

    /// The walk runs off the main thread, so this one is answered here. It
    /// does hold this server's queue for the length of the walk, which is the
    /// point: the number it reports is that walk's real cost.
    private func probeVocabulary(app: String?) -> [String: String] {
        guard let vocabularyProbe else { return ["error": "no probe"] }
        return vocabularyProbe(app)
    }

    private func probeKeyBurst(count: Int) -> [String: String] {
        guard let keyBurstProbe else { return ["error": "no probe"] }
        return onMainThread(timeout: 6) { keyBurstProbe(count) }
    }

    private func probeFocus() -> [String: String] {
        guard let focusProbe else { return ["error": "no probe"] }
        return onMainThread(focusProbe)
    }

    /// Reading the focused field walks the live UI tree from the main thread,
    /// the way the typing does.
    private func onMainThread(
        timeout: TimeInterval = MacDebugHTTPServer.probeTimeout,
        _ probe: @escaping @Sendable () -> [String: String]
    ) -> [String: String] {
        let box = MainThreadResultBox()
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.value = probe()
            ready.signal()
        }
        guard ready.wait(timeout: .now() + timeout) == .success else {
            return ["error": "main thread busy"]
        }
        return box.value ?? [:]
    }

    private func writePortFile(port: UInt16) {
        let payload: [String: Any] = [
            "app": "NewMotion",
            "host": "127.0.0.1",
            "port": Int(port),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "url": "http://127.0.0.1:\(port)/state"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: portFileURL, options: .atomic)
    }
}

/// Hands one probe result back from the main thread.  The semaphore is the
/// only synchronisation it needs: nothing reads it before that signal.
private final class MainThreadResultBox: @unchecked Sendable {
    var value: [String: String]?
}
