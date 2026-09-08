import Foundation

#if os(macOS)
import AppKit
import ApplicationServices
#endif

/// What the focused field had to say, and when it could not say it, why. The
/// label is safe for logs and the debug server; the text it stands for never
/// is, so only the label ever leaves this type.
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

/// The field either side of the caret.  A held delete key only ever erases
/// from the caret backwards, so `head` is the part that shrinks and `tail` is
/// the part that has to stay put for a reading to mean anything: a caret that
/// moved without deleting shows up as a tail that grew.
public enum FocusedCaretText: Equatable, Sendable {
    case split(head: String, tail: String)
    case unavailable(String)

    public var label: String {
        switch self {
        case .split: "split"
        case let .unavailable(reason): reason
        }
    }
}

/// Reads the text already sitting in the field that spoken words will join.
public protocol FocusedTextReading: Sendable {
    func focusedText() -> FocusedText

    /// The field either side of the caret.  A requirement rather than only an
    /// extension, so a reader that can see the caret is actually asked.
    func textAroundCaret() -> FocusedCaretText

    /// Called as the press begins. A field that has to be woken before it can
    /// be read gets that head start here instead of stalling the first read.
    func prepare()
}

public extension FocusedTextReading {
    func prepare() {}

    /// A reader that cannot see the caret.  Only the Accessibility reader can.
    func textAroundCaret() -> FocusedCaretText { .unavailable("noCaretRead") }
}

#if os(macOS)
/// Reads the focused field through Accessibility, the permission the app
/// already holds in order to type. Nothing is written back through this path.
public final class AXFocusedTextReader: FocusedTextReading {
    /// Long enough for a busy app to answer, short enough that a wedged one
    /// costs the utterance a quarter second instead of the whole thing.
    private static let messagingTimeout: Float = 0.25
    /// Past this the field is a document rather than an input, and walking the
    /// whole of one to find the caret costs more than the read is worth.
    static let maximumUnits = 4_000

    public init() {}

    public func prepare() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        // This runs on every press of a delete key, on the actor that carries
        // the cursor, and an attribute write waits six seconds by default.
        // Chromium only sets a flag here and builds the tree afterwards on its
        // own time, so there is nothing worth waiting longer than a read for.
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        wakeAccessibilityTree(of: application)
    }

    public func focusedText() -> FocusedText {
        let focused = focusedElement()
        guard let field = focused.value else { return .unavailable(label("focus", focused.error)) }
        AXUIElementSetMessagingTimeout(field, Self.messagingTimeout)

        let value: (value: String?, error: AXError) = copy(kAXValueAttribute, from: field)
        guard let text = value.value else { return .unavailable(label("value", value.error)) }
        let units = (text as NSString).length
        guard units <= Self.maximumUnits else { return .unavailable("tooLong") }

        // A whole-field read only means anything with the caret at the end;
        // anywhere else and what follows the caret is missing from it.
        let range: (value: AXValue?, error: AXError) = copy(kAXSelectedTextRangeAttribute, from: field)
        guard let selected = range.value else { return .unavailable(label("range", range.error)) }
        var caret = CFRange()
        guard AXValueGetValue(selected, .cfRange, &caret) else { return .unavailable("range:shape") }
        guard caret.length == 0, caret.location == units else { return .unavailable("caretNotAtEnd") }
        return .text(text)
    }

    /// Where the caret is and what sits either side of it.  Unlike
    /// `focusedText`, this does not insist the caret be at the very end: a
    /// held delete key erases backwards from wherever it is, and after a slide
    /// that ran past the start of a line it very often is not at the end.
    /// This is the read the delete key uses; `focusedText` only serves the
    /// debug server's account of what Accessibility can see.
    public func textAroundCaret() -> FocusedCaretText {
        let focused = focusedElement()
        guard let field = focused.value else { return .unavailable(label("focus", focused.error)) }
        AXUIElementSetMessagingTimeout(field, Self.messagingTimeout)

        let value: (value: String?, error: AXError) = copy(kAXValueAttribute, from: field)
        guard let text = value.value else { return .unavailable(label("value", value.error)) }
        let units = (text as NSString).length
        guard units <= Self.maximumUnits else { return .unavailable("tooLong") }

        let range: (value: AXValue?, error: AXError) = copy(kAXSelectedTextRangeAttribute, from: field)
        guard let selected = range.value else { return .unavailable(label("range", range.error)) }
        var caret = CFRange()
        guard AXValueGetValue(selected, .cfRange, &caret) else { return .unavailable("range:shape") }
        // A selection is not a caret, and Delete would take the selection
        // instead of the character before it.
        guard caret.length == 0 else { return .unavailable("selection") }
        guard caret.location >= 0, caret.location <= units else { return .unavailable("range:bounds") }
        // Chromium, and so every Electron app, hands back a container element
        // for a contenteditable every so often, and a container does not track
        // the caret: it answers {0, 0} while its value holds the whole field.
        // Read as truth that says the whole field sits behind the caret, which
        // is indistinguishable from the field having been emptied.  A caret
        // genuinely at the start has nothing in front of it for a delete key to
        // take, so refusing both costs nothing and the next read gets the real
        // element.
        guard caret.location > 0 || units == 0 else { return .unavailable("range:zero") }
        let field_ = text as NSString
        return .split(
            head: field_.substring(to: caret.location),
            tail: field_.substring(from: caret.location)
        )
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
