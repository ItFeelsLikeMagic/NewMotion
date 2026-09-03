import Foundation

#if os(macOS)
import AppKit
import ApplicationServices
#endif

/// What the focused field had to say. Anything but `.text` sends voice typing
/// back to plain appending, and the label says why. The label is safe for logs
/// and the debug snapshot; the text it stands for never is.
public enum FocusedText: Equatable, Sendable {
    case text(String)
    case unavailable(String)

    public var label: String {
        switch self {
        case let .text(value): value.isEmpty ? "emptyField" : "field"
        case let .unavailable(reason): reason
        }
    }
}

/// Reads the text already sitting in the field that spoken words will join.
public protocol FocusedTextReading: Sendable {
    func focusedText() -> FocusedText

    /// Called when the speaker starts talking. A field that has to be woken
    /// before it can be read gets that head start here instead of stalling the
    /// read at the end of the sentence.
    func prepare()
}

public extension FocusedTextReading {
    func prepare() {}
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

    public func prepare() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        wakeAccessibilityTree(of: AXUIElementCreateApplication(frontmost.processIdentifier))
    }

    public func focusedText() -> FocusedText {
        let focused = focusedElement()
        guard let field = focused.value else { return .unavailable(label("focus", focused.error)) }
        AXUIElementSetMessagingTimeout(field, Self.messagingTimeout)

        let value: (value: String?, error: AXError) = copy(kAXValueAttribute, from: field)
        guard let text = value.value else { return .unavailable(label("value", value.error)) }
        let units = (text as NSString).length
        guard units <= Self.maximumUnits else { return .unavailable("tooLong") }

        // Typing lands at the caret, so a caret anywhere but the end would put
        // the merged text somewhere the speaker did not ask for.
        let range: (value: AXValue?, error: AXError) = copy(kAXSelectedTextRangeAttribute, from: field)
        guard let selected = range.value else { return .unavailable(label("range", range.error)) }
        var caret = CFRange()
        guard AXValueGetValue(selected, .cfRange, &caret) else { return .unavailable("range:shape") }
        guard caret.length == 0, caret.location == units else { return .unavailable("caretNotAtEnd") }
        return .text(text)
    }

    /// A label-only account of what Accessibility can see right now, for the
    /// debug server. Field text never appears here, only roles and error codes.
    public func diagnostics() -> [String: String] {
        var report = [
            "trusted": AXIsProcessTrusted() ? "yes" : "no",
            "result": focusedText().label
        ]
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            report["frontmost"] = frontmost.bundleIdentifier ?? "unknown"
            let application = AXUIElementCreateApplication(frontmost.processIdentifier)
            AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
            report["appFocus"] = role(ofFocusedElementOf: application)
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        report["systemFocus"] = role(ofFocusedElementOf: system)
        return report
    }

    /// Asking the frontmost app for its focused element is more reliable than
    /// asking the system-wide element, which answers "no value" for some apps.
    /// The system-wide element stays as the fallback for the rest.
    private func focusedElement() -> (value: AXUIElement?, error: AXError) {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let application = AXUIElementCreateApplication(frontmost.processIdentifier)
            AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
            wakeAccessibilityTree(of: application)
            let focused: (value: AXUIElement?, error: AXError) = copy(kAXFocusedUIElementAttribute, from: application)
            if focused.value != nil { return focused }
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        return copy(kAXFocusedUIElementAttribute, from: system)
    }

    private func role(ofFocusedElementOf element: AXUIElement) -> String {
        let focused: (value: AXUIElement?, error: AXError) = copy(kAXFocusedUIElementAttribute, from: element)
        guard let field = focused.value else { return label("focus", focused.error) }
        let role: (value: String?, error: AXError) = copy(kAXRoleAttribute, from: field)
        return role.value ?? label("role", role.error)
    }

    /// Chromium, and so every Electron app, keeps its accessibility tree off
    /// until a client asks for it by name, and then builds it in its own time.
    /// Without this an Electron text box reports no focused element at all.
    /// Other apps ignore the attribute.
    private func wakeAccessibilityTree(of application: AXUIElement) {
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func copy<T>(_ attribute: String, from element: AXUIElement) -> (value: T?, error: AXError) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        return (raw as? T, error)
    }

    /// A successful read that still yielded nothing means the element answered
    /// with something that is not text, which is a different fault to chase.
    private func label(_ stage: String, _ error: AXError) -> String {
        error == .success ? "\(stage):notText" : "\(stage):\(error.rawValue)"
    }
}
#endif
