import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// What a debug request may put on the on-screen card. Deliberately not a
/// string: a named grid cell or the one fixed hint, and never arbitrary words.
public enum MacDebugCardRequest: Equatable, Sendable {
    case picker(cell: String?)
    case hint
}

public enum MacDebugHTTP {
    public static let defaultPort: UInt16 = 18765
    public static let portFileURL = URL(fileURLWithPath: "/tmp/newmotion-mac-debug.json")

    public struct Response: Equatable {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int, contentType: String, body: Data) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        public var httpData: Data {
            let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return Data(header.utf8) + body
        }

        private var reason: String {
            switch status {
            case 200: return "OK"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            default: return "Error"
            }
        }
    }

    public static func handle(
        request: String,
        snapshot: MacDebugSnapshot,
        focus: () -> [String: String] = { [:] },
        vocabulary: (String?) -> [String: String] = { _ in [:] },
        keyBurst: (Int) -> [String: String] = { _ in [:] },
        latency: () -> [LatencySummary] = { [] },
        card: (MacDebugCardRequest) -> [String: String] = { _ in [:] }
    ) -> Response {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return json(status: 400, object: ["error": "empty request"])
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return json(status: 400, object: ["error": "bad request"])
        }
        let method = String(parts[0])
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
        let path = String(target.first ?? parts[1])
        // `/vocabulary?app=com.apple.Notes` measures a named app in place.
        let query = target.count > 1 ? String(target[1]) : ""
        let app = query.split(separator: "&").first { $0.hasPrefix("app=") }
            .map { String($0.dropFirst("app=".count)).removingPercentEncoding ?? "" }
        // `/keyburst?count=40` presses Delete that many times in one burst.
        let count = query.split(separator: "&").first { $0.hasPrefix("count=") }
            .flatMap { Int(String($0.dropFirst("count=".count))) }
        // `/picker?cell=save` lights one cell of the grid, by display name,
        // ignoring case and spaces.
        let cell = query.split(separator: "&").first { $0.hasPrefix("cell=") }
            .map { String($0.dropFirst("cell=".count)) }
        guard method == "GET" else {
            return json(status: 405, object: ["error": "method not allowed"])
        }
        switch path {
        case "/", "/state":
            var live = snapshot
            live.latency = latency()
            return encode(live)
        case "/health":
            return json(status: 200, object: ["ok": true, "app": "NewMotion"])
        // What Accessibility can see in the focused field right now.  Labels
        // and error codes only; the field's text never leaves the app.
        case "/focus":
            return json(status: 200, object: focus())
        // Runs one front-window vocabulary walk and reports what it cost.
        // Counts and milliseconds only; the words never leave the app.
        case "/vocabulary":
            return json(status: 200, object: vocabulary(app?.isEmpty == false ? app : nil))
        // Presses Delete `count` times into whatever is focused and reports how
        // many characters actually left.  This is how the gap inside a run was
        // settled rather than guessed at.  Lengths only; no text leaves the app.
        case "/keyburst":
            return json(status: 200, object: keyBurst(count ?? 20))
        // Drives the card with no phone on the link.  A cell of the picker
        // grid by display name, or the delete hint; a request with no cell
        // closes the picker.  Nothing here puts arbitrary words on the screen.
        case "/picker":
            return json(status: 200, object: card(.picker(cell: cell?.isEmpty == false ? cell : nil)))
        case "/hint":
            return json(status: 200, object: card(.hint))
        default:
            return json(status: 404, object: ["error": "not found"])
        }
    }

    public static func encode(_ snapshot: MacDebugSnapshot) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return Response(status: 200, contentType: "application/json", body: try encoder.encode(snapshot))
        } catch {
            return json(status: 500, object: ["error": "encode failed"])
        }
    }

    private static func json(status: Int, object: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{}"#.utf8)
        return Response(status: status, contentType: "application/json", body: data)
    }
}
