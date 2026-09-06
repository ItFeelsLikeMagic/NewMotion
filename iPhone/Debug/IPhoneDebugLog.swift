import Foundation

private let iPhoneDebugBlockedKeys = ["qr", "secret", "token", "key", "udid", "payload"]

private func iPhoneDebugStamp() -> String {
    String(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000)
}

/// Privacy-safe iPhone debug log. Never records QR text, secrets, keys, or
/// device identifiers. Written to the app Documents folder so it can be
/// copied off the phone with `devicectl device copy from`.
///
/// Debug builds only: in release the emit calls compile away, so a shipped app
/// writes no log file and shows no log screen. Call sites stay unchanged.
@MainActor
final class IPhoneDebugLog: ObservableObject {
    static let shared = IPhoneDebugLog()
    nonisolated static let fileName = "newmotion-debug.jsonl"
    nonisolated static let snapshotName = "newmotion-debug-state.json"

    @Published private(set) var lines: [String] = []
    private var snapshot: [String: String] = [:]

    nonisolated static func emit(_ name: String, _ fields: [String: String] = [:]) {
#if DEBUG
        let safe = fields.filter { key, _ in
            let lower = key.lowercased()
            return !iPhoneDebugBlockedKeys.contains(where: { lower.contains($0) })
        }
        var parts = ["t=\(iPhoneDebugStamp())", "e=\(name)"]
        for key in safe.keys.sorted() {
            parts.append("\(key)=\(safe[key] ?? "")")
        }
        let line = parts.joined(separator: " ")
        NSLog("PRDBG %@", line)
        Task { @MainActor in shared.record(name, safe, line) }
#endif
    }

    func event(_ name: String, _ fields: [String: String] = [:]) {
        Self.emit(name, fields)
    }

    private func record(_ name: String, _ safe: [String: String], _ line: String) {
        lines.append(line)
        if lines.count > 24 { lines.removeFirst(lines.count - 24) }
        for (key, value) in safe { snapshot["\(name).\(key)"] = value }
        snapshot["lastEvent"] = name
        snapshot["lastLine"] = line
        Self.write(line: line, snapshot: snapshot)
    }

    func note(_ key: String, _ value: String) {
#if DEBUG
        let lower = key.lowercased()
        guard !iPhoneDebugBlockedKeys.contains(where: { lower.contains($0) }) else { return }
        snapshot[key] = value
        Self.write(line: nil, snapshot: snapshot)
#endif
    }

    var onScreen: String { lines.suffix(8).joined(separator: "\n") }

    /// Two file writes per event are far too slow for the main thread, and the
    /// press path is timed through this log.  The serial queue keeps the file
    /// in event order.
    private nonisolated static let io = DispatchQueue(label: "newmotion.debuglog", qos: .utility)

    private nonisolated static func write(line: String?, snapshot: [String: String]) {
        io.async {
            if let line { appendFile(line) }
            writeSnapshot(snapshot)
        }
    }

    private nonisolated static func appendFile(_ line: String) {
        guard let url = documentsURL?.appendingPathComponent(fileName) else { return }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    private nonisolated static func writeSnapshot(_ snapshot: [String: String]) {
        guard let url = documentsURL?.appendingPathComponent(snapshotName) else { return }
        let body = snapshot.keys.sorted().map { "\($0)=\(snapshot[$0] ?? "")" }.joined(separator: "\n")
        try? (body + "\n").data(using: .utf8)?.write(to: url)
    }

    private nonisolated static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
