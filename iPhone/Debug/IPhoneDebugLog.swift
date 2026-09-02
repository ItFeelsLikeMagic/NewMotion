import Foundation

private let iPhoneDebugBlockedKeys = ["qr", "secret", "token", "key", "udid", "payload"]

private func iPhoneDebugStamp() -> String {
    String(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000)
}

/// Privacy-safe iPhone debug log. Never records QR text, secrets, keys, or
/// device identifiers. Written to the app Documents folder so it can be
/// copied off the phone with `devicectl device copy from`.
@MainActor
final class IPhoneDebugLog: ObservableObject {
    static let shared = IPhoneDebugLog()
    static let fileName = "phoneremote-debug.jsonl"
    static let snapshotName = "phoneremote-debug-state.json"

    @Published private(set) var lines: [String] = []
    private var snapshot: [String: String] = [:]

    nonisolated static func emit(_ name: String, _ fields: [String: String] = [:]) {
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
        appendFile(line)
        writeSnapshot()
    }

    func note(_ key: String, _ value: String) {
        let lower = key.lowercased()
        guard !iPhoneDebugBlockedKeys.contains(where: { lower.contains($0) }) else { return }
        snapshot[key] = value
        writeSnapshot()
    }

    var onScreen: String { lines.suffix(8).joined(separator: "\n") }

    private func appendFile(_ line: String) {
        guard let url = Self.documentsURL?.appendingPathComponent(Self.fileName) else { return }
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

    private func writeSnapshot() {
        guard let url = Self.documentsURL?.appendingPathComponent(Self.snapshotName) else { return }
        let body = snapshot.keys.sorted().map { "\($0)=\(snapshot[$0] ?? "")" }.joined(separator: "\n")
        try? (body + "\n").data(using: .utf8)?.write(to: url)
    }

    private static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
