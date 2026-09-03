import Foundation

public enum TranscriptionError: Error, Equatable, Sendable {
    case serverUnavailable
    case connectionFailed
    case serverError
}

/// One utterance's connection to the recogniser. Audio is forwarded as it
/// arrives; `commit` asks for the final text. Handlers may run on any thread.
public protocol TranscriptionSession: AnyObject {
    func send(pcm16: [Int16])
    func commit()
    /// The speaker threw the utterance away. The session is torn down without
    /// asking for text, and its handlers must not fire again.
    func cancel()
}

public extension TranscriptionSession {
    func cancel() {}
}

public struct TranscriptionSessionHandlers: Sendable {
    public let onDelta: @Sendable (String) -> Void
    public let onResult: @Sendable (Result<String, TranscriptionError>) -> Void

    public init(
        onDelta: @escaping @Sendable (String) -> Void,
        onResult: @escaping @Sendable (Result<String, TranscriptionError>) -> Void
    ) {
        self.onDelta = onDelta
        self.onResult = onResult
    }
}

public protocol TranscriptionSessionFactory: Sendable {
    func makeSession(handlers: TranscriptionSessionHandlers) -> TranscriptionSession
}

/// Server-to-client events on nemo-speech's `/v1/realtime` WebSocket.
public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case delta(String)
    case completed(transcript: String)
    case committed
    case cleared
    case error(message: String)

    public static func parse(_ text: String) -> RealtimeServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            return .delta(object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(transcript: object["transcript"] as? String ?? "")
        case "input_audio_buffer.committed":
            return .committed
        case "input_audio_buffer.cleared":
            return .cleared
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(message: error?["message"] as? String ?? "")
        default:
            return nil
        }
    }
}
