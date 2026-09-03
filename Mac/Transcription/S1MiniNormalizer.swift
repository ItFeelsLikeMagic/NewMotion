import Foundation

/// Rewrites one finished transcript as clean written text. Implementations
/// must always call back; on any failure they return the text unchanged.
public protocol TranscriptNormalizer: Sendable {
    func normalize(_ transcript: String, completion: @escaping @Sendable (String) -> Void)
}

/// "S1-mini" by "Superwhisper", a 0.6B normalizer that strips fillers, resolves
/// false starts, and writes out numbers, dates and addresses. It is not a chat
/// model: the system prompt, the control line, the empty think block and greedy
/// decoding are the format it was trained on, so this uses Ollama's raw
/// completion endpoint rather than a chat template that could drift.
public final class S1MiniNormalizer: TranscriptNormalizer {
    public static let defaultPort = 11434
    public static let defaultModel = "s1-mini"

    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    static let controlLine = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    /// Slower than the model's worst observed pass, short enough that a stall
    /// types the raw transcript instead of leaving the user waiting.
    private static let timeout: TimeInterval = 5
    /// How long Ollama keeps the weights resident between utterances.
    private static let keepAlive = "10m"

    private let url: URL
    private let model: String
    private let http = URLSession(configuration: .ephemeral)

    public init(port: Int? = nil, model: String? = nil) {
        let port = port
            ?? ProcessInfo.processInfo.environment["PHONE_REMOTE_S1_PORT"].flatMap(Int.init)
            ?? Self.defaultPort
        self.url = URL(string: "http://127.0.0.1:\(port)/api/generate")!
        self.model = model
            ?? ProcessInfo.processInfo.environment["PHONE_REMOTE_S1_MODEL"]
            ?? Self.defaultModel
    }

    /// Loads the weights so the first real utterance does not pay for it.
    public func warmUp() {
        normalize("hello", completion: { _ in })
    }

    public func normalize(_ transcript: String, completion: @escaping @Sendable (String) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": Self.prompt(for: transcript),
            "raw": true,
            "stream": false,
            "keep_alive": Self.keepAlive,
            "options": ["temperature": 0, "num_ctx": 4096]
        ]) else {
            completion(transcript)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = Self.timeout
        http.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let normalized = Self.normalized(fromResponse: data) else {
                completion(transcript)
                return
            }
            completion(normalized)
        }.resume()
    }

    /// The trained prefix. The assistant turn opens with an empty think block
    /// because the model was trained with thinking off.
    static func prompt(for transcript: String) -> String {
        "<|im_start|>system\n" + systemPrompt + "<|im_end|>\n"
            + "<|im_start|>user\n" + controlLine + "\n" + transcript + "<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Nil when the payload is not a completion; an empty string is a real
    /// result for filler-only speech.
    static func normalized(fromResponse data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? String else {
            return nil
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
