import Foundation

public enum MacDebugHTTP {
    public static let defaultPort: UInt16 = 18765
    public static let portFileURL = URL(fileURLWithPath: "/tmp/phoneremote-mac-debug.json")

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
        focus: () -> [String: String] = { [:] }
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
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first ?? parts[1])
        guard method == "GET" else {
            return json(status: 405, object: ["error": "method not allowed"])
        }
        switch path {
        case "/", "/state":
            return encode(snapshot)
        case "/health":
            return json(status: 200, object: ["ok": true, "app": "PhoneRemoteMac"])
        // What Accessibility can see in the focused field right now.  Labels
        // and error codes only; the field's text never leaves the app.
        case "/focus":
            return json(status: 200, object: focus())
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
