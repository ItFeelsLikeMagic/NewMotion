import Foundation

public enum SpeechAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

public enum SpeechTranscriptionError: Error, Equatable, Sendable {
    case permissionDenied
    case recognizerUnavailable
    case invalidAudioURL
    case failed
}

public protocol SpeechTranscriptionProviding: AnyObject {
    func requestAuthorization(completion: @escaping @Sendable (SpeechAuthorizationState) -> Void)
    func transcribeWAV(at url: URL, completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void)
}

public protocol StreamingSpeechProviding: AnyObject {
    func beginUtterance()
    func appendPCM16(_ samples: [Int16])
    func endUtterance(completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void)
    func cancelUtterance()
}

/// Mac-side orchestration for a completed WAV.  The adapter reports only the
/// final transcript to its caller; it has no diagnostic logging hook.
public final class SpeechTranscriptionController: @unchecked Sendable {
    private let provider: SpeechTranscriptionProviding
    private(set) public var authorization: SpeechAuthorizationState = .notDetermined
    private(set) public var finalTranscript: String?

    public init(provider: SpeechTranscriptionProviding) {
        self.provider = provider
    }

    public func requestPermission(completion: @escaping @Sendable (SpeechAuthorizationState) -> Void) {
        provider.requestAuthorization { [weak self] state in
            self?.authorization = state
            completion(state)
        }
    }

    public func transcribe(
        wavURL: URL,
        completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void
    ) {
        guard authorization == .authorized else {
            completion(.failure(.permissionDenied))
            return
        }
        provider.transcribeWAV(at: wavURL) { [weak self] result in
            if case let .success(value) = result {
                self?.finalTranscript = value
            }
            completion(result)
        }
    }
}

public protocol SafeTranscriptInsertionSink: AnyObject {
    /// Implementations must route this through the existing SAFE-001/SAFE-002
    /// text policy.  This protocol does not expose CGEvent or raw key codes.
    @discardableResult
    func insertTranscript(_ text: String) -> Bool
}

/// Requires a local explicit call to insert; receiving a transcript never
/// injects text automatically.
public final class ExplicitTranscriptInsertionController {
    private let insertionSink: SafeTranscriptInsertionSink
    private(set) public var pendingTranscript: String?

    public init(insertionSink: SafeTranscriptInsertionSink) {
        self.insertionSink = insertionSink
    }

    public func receiveFinalTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        pendingTranscript = text
    }

    @discardableResult
    public func insertPendingTranscript() -> Bool {
        guard let pendingTranscript, !pendingTranscript.isEmpty else { return false }
        guard insertionSink.insertTranscript(pendingTranscript) else { return false }
        self.pendingTranscript = nil
        return true
    }

    public func discardPendingTranscript() {
        pendingTranscript = nil
    }
}

/// Deterministic test adapter.  It lets simulator tests prove permission and
/// explicit-insertion behavior without a microphone, Speech server, or audio
/// payload fixture.
public final class TestSpeechTranscriptionProvider: SpeechTranscriptionProviding, @unchecked Sendable {
    public var authorizationToReturn: SpeechAuthorizationState
    public var resultToReturn: Result<String, SpeechTranscriptionError>
    public private(set) var requestedURL: URL?

    public init(
        authorization: SpeechAuthorizationState = .authorized,
        result: Result<String, SpeechTranscriptionError> = .success("test transcript")
    ) {
        self.authorizationToReturn = authorization
        self.resultToReturn = result
    }

    public func requestAuthorization(completion: @escaping @Sendable (SpeechAuthorizationState) -> Void) {
        completion(authorizationToReturn)
    }

    public func transcribeWAV(at url: URL, completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void) {
        requestedURL = url
        completion(resultToReturn)
    }
}

public final class TestStreamingSpeechProvider: StreamingSpeechProviding, @unchecked Sendable {
    public var resultToReturn: Result<String, SpeechTranscriptionError>
    public private(set) var began = 0
    public private(set) var ended = 0
    public private(set) var cancelled = 0
    public private(set) var samples: [Int16] = []

    public init(result: Result<String, SpeechTranscriptionError> = .success("hello world")) {
        self.resultToReturn = result
    }

    public func beginUtterance() {
        began += 1
        samples.removeAll(keepingCapacity: true)
    }

    public func appendPCM16(_ samples: [Int16]) {
        self.samples.append(contentsOf: samples)
    }

    public func endUtterance(completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void) {
        ended += 1
        completion(resultToReturn)
    }

    public func cancelUtterance() {
        cancelled += 1
        samples.removeAll(keepingCapacity: true)
    }
}

public final class DeferredStreamingSpeechProvider: StreamingSpeechProviding, @unchecked Sendable {
    private let makeProvider: () -> StreamingSpeechProviding?
    private var provider: StreamingSpeechProviding?
    private let lock = NSLock()

    public init(makeProvider: @escaping () -> StreamingSpeechProviding?) {
        self.makeProvider = makeProvider
    }

    private func resolved() -> StreamingSpeechProviding? {
        lock.lock()
        defer { lock.unlock() }
        if provider == nil {
            provider = makeProvider()
        }
        return provider
    }

    public func beginUtterance() {
        resolved()?.beginUtterance()
    }

    public func appendPCM16(_ samples: [Int16]) {
        resolved()?.appendPCM16(samples)
    }

    public func endUtterance(completion: @escaping @Sendable (Result<String, SpeechTranscriptionError>) -> Void) {
        guard let provider = resolved() else {
            completion(.failure(.recognizerUnavailable))
            return
        }
        provider.endUtterance(completion: completion)
    }

    public func cancelUtterance() {
        resolved()?.cancelUtterance()
    }
}


