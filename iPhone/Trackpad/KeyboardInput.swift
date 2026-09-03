import Foundation

/// Text is bounded before it reaches the protocol adapter.  Chunking iterates
/// Character values, so a UTF-8 sequence or grapheme cluster is never split.
public struct TextEntryChunk: Equatable, Sendable {
    public let index: Int
    public let total: Int
    public let value: String

    public init(index: Int, total: Int, value: String) {
        self.index = index
        self.total = total
        self.value = value
    }
}

public enum TextEntryFailure: String, Equatable, Sendable {
    case empty
    case tooLarge
    case invalidUnicode
}

public enum TextEntryResult: Equatable, Sendable {
    case chunks([TextEntryChunk])
    case rejected(TextEntryFailure)
}

public struct UnicodeTextEntryPolicy: Equatable, Sendable {
    public let maximumUTF8Bytes: Int
    public let maximumChunkUTF8Bytes: Int

    public init(maximumUTF8Bytes: Int = 64 * 1024, maximumChunkUTF8Bytes: Int = 4_096) {
        self.maximumUTF8Bytes = max(1, maximumUTF8Bytes)
        self.maximumChunkUTF8Bytes = min(max(1, maximumChunkUTF8Bytes), max(1, maximumUTF8Bytes))
    }
}

public struct UnicodeTextEntryChunker: Sendable {
    public let policy: UnicodeTextEntryPolicy

    public init(policy: UnicodeTextEntryPolicy = UnicodeTextEntryPolicy()) {
        self.policy = policy
    }

    public func chunk(_ text: String) -> TextEntryResult {
        guard !text.isEmpty else { return .rejected(.empty) }
        guard text.utf8.count <= policy.maximumUTF8Bytes else { return .rejected(.tooLarge) }
        guard text.unicodeScalars.allSatisfy({ $0.isASCII || $0.value <= 0x10FFFF }) else {
            return .rejected(.invalidUnicode)
        }

        var values: [String] = []
        var current = String()
        var currentBytes = 0
        for character in text {
            let value = String(character)
            let bytes = value.utf8.count
            if !current.isEmpty && currentBytes + bytes > policy.maximumChunkUTF8Bytes {
                values.append(current)
                current = String()
                currentBytes = 0
            }
            // A single extended grapheme cluster may theoretically exceed the
            // chunk bound.  It is still delivered atomically as one chunk.
            current.append(contentsOf: value)
            currentBytes += bytes
        }
        if !current.isEmpty { values.append(current) }
        let total = values.count
        return .chunks(values.enumerated().map { TextEntryChunk(index: $0.offset, total: total, value: $0.element) })
    }
}

public enum RemoteHotkey: String, CaseIterable, Equatable, Hashable, Sendable {
    case copy
    case paste
    case undo
    case redo
    case selectAll
    case escape
    case `return`
    case tab
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case deleteBackward
    case deleteWordBackward
    case deleteLineBackward
}

public enum KeyboardOutput: Equatable, Sendable {
    case text(TextEntryChunk)
    case hotkey(RemoteHotkey)
}

public protocol KeyboardOutputSink: AnyObject {
    func send(_ output: KeyboardOutput)
}

/// Local keyboard controller.  Characters leave as they are typed and are
/// never retained, so there is no draft, history, or diagnostic entry.
public final class KeyboardInputController {
    private let chunker: UnicodeTextEntryChunker
    private let sink: KeyboardOutputSink

    public init(
        chunker: UnicodeTextEntryChunker = UnicodeTextEntryChunker(),
        sink: KeyboardOutputSink
    ) {
        self.chunker = chunker
        self.sink = sink
    }

    @discardableResult
    public func type(_ text: String) -> TextEntryResult {
        let result = chunker.chunk(text)
        if case let .chunks(chunks) = result {
            chunks.forEach { sink.send(.text($0)) }
        }
        return result
    }

    public func send(_ hotkey: RemoteHotkey) {
        sink.send(.hotkey(hotkey))
    }
}

/// Mirrors RemoteInputEventForwarder so the feature model can receive keyboard
/// output without the controller knowing about the transport.
public final class KeyboardOutputForwarder: KeyboardOutputSink {
    public typealias Handler = (KeyboardOutput) -> Void
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ output: KeyboardOutput) {
        handler(output)
    }
}
