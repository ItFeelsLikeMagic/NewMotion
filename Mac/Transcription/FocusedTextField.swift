import Foundation

#if os(macOS)
import ApplicationServices
#endif

/// Reads the text already sitting in the field that spoken words will join.
/// The value is display-only: it must never be logged or written to the debug
/// snapshot.
public protocol FocusedTextReading: Sendable {
    /// The whole text of the focused field, empty when the field is empty, or
    /// nil when it cannot be read or the caret is not sitting at its end.
    func focusedText() -> String?
}

/// Joins what is already in the field to what was just spoken, and works out
/// the smallest edit that turns one into the other.
public enum TranscriptMerge {
    /// Each deletion costs about 20 ms and visibly rewinds text the speaker can
    /// see, so the budget covers a reworded last sentence and nothing larger.
    public static let maximumDeletions = 40

    public struct Edit: Equatable, Sendable {
        public var deletions: Int
        public var insertion: String
    }

    /// What the normalizer sees: everything already in the field followed by
    /// the new words, so it can punctuate and space across the join instead of
    /// starting a fresh sentence on every press.
    public static func payload(existing: String, transcript: String) -> String {
        existing + tail(existing: existing, transcript: transcript)
    }

    /// The joining text on its own, for when the whole rewrite cannot be applied.
    public static func tail(existing: String, transcript: String) -> String {
        guard !existing.isEmpty, existing.last?.isWhitespace == false else { return transcript }
        return " " + transcript
    }

    /// Nil when the rewrite would rewind more than the budget allows.
    public static func edit(from existing: String, to merged: String) -> Edit? {
        let existingCharacters = Array(existing)
        let mergedCharacters = Array(merged)
        var shared = 0
        while shared < existingCharacters.count,
              shared < mergedCharacters.count,
              existingCharacters[shared] == mergedCharacters[shared] {
            shared += 1
        }
        let deletions = existingCharacters.count - shared
        guard deletions <= maximumDeletions else { return nil }
        return Edit(deletions: deletions, insertion: String(mergedCharacters[shared...]))
    }
}

#if os(macOS)
/// Reads the focused field through Accessibility, the permission the app
/// already holds in order to type. Nothing is written back through this path.
public final class AXFocusedTextReader: FocusedTextReading {
    /// Long enough for a busy app to answer, short enough that a wedged one
    /// costs the utterance a quarter second instead of the whole thing.
    private static let messagingTimeout: Float = 0.25
    /// Past this the field is a document rather than an input, and rewriting it
    /// around one spoken sentence is not what the speaker meant.
    static let maximumUnits = 4_000

    public init() {}

    public func focusedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        guard let field: AXUIElement = copy(kAXFocusedUIElementAttribute, from: system) else { return nil }
        AXUIElementSetMessagingTimeout(field, Self.messagingTimeout)
        guard let text: String = copy(kAXValueAttribute, from: field) else { return nil }
        let units = (text as NSString).length
        guard units <= Self.maximumUnits else { return nil }

        // Typing lands at the caret, so a caret anywhere but the end would put
        // the merged text somewhere the speaker did not ask for.
        guard let range: AXValue = copy(kAXSelectedTextRangeAttribute, from: field) else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(range, .cfRange, &selection),
              selection.length == 0,
              selection.location == units else { return nil }
        return text
    }

    private func copy<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
#endif
