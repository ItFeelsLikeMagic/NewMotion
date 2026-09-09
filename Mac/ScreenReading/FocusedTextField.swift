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

/// What sits in front of the caret.  A held delete key only ever erases from
/// the caret backwards, so the text behind it is the only part worth reading.
///
/// On a field short enough to copy whole, `head` is everything before the
/// caret.  On a longer one it is a window on to the end of that, which is what
/// keeps a read costing the same on a note of any length.  `reachesStart` is
/// what tells the two apart: false means `head` running out is the edge of the
/// window and not the beginning of the text.
public enum FocusedCaretText: Equatable, Sendable {
    case split(head: String, reachesStart: Bool)
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
    /// The most text one read will copy.  A field under it is read whole; a
    /// longer one is read as the window of this many characters in front of the
    /// caret, so what a read costs stays flat as a note grows.  The debug
    /// server's whole-field read has no window to fall back on and refuses
    /// anything past it.
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

    /// Where the caret is and what sits in front of it.  Unlike `focusedText`,
    /// this does not insist the caret be at the very end: a held delete key
    /// erases backwards from wherever it is, and after a slide that ran past
    /// the start of a line it very often is not at the end.
    ///
    /// A field too long to copy is asked for the window in front of its caret
    /// instead of the whole of its text.  Copying a whole note on the actor
    /// that carries the cursor is what a delete key in a long note used to
    /// cost, and it was thrown away unread for being too long.  This is the
    /// read the delete key uses; `focusedText` only serves the debug server's
    /// account of what Accessibility can see.
    public func textAroundCaret() -> FocusedCaretText {
        let focused = focusedElement()
        guard let field = focused.value else { return .unavailable(label("focus", focused.error)) }
        AXUIElementSetMessagingTimeout(field, Self.messagingTimeout)

        let range: (value: AXValue?, error: AXError) = copy(kAXSelectedTextRangeAttribute, from: field)
        guard let selected = range.value else { return .unavailable(label("range", range.error)) }
        var caret = CFRange()
        guard AXValueGetValue(selected, .cfRange, &caret) else { return .unavailable("range:shape") }
        // A selection is not a caret, and Delete would take the selection
        // instead of the character before it.
        guard caret.length == 0 else { return .unavailable("selection") }
        guard caret.location >= 0 else { return .unavailable("range:bounds") }

        // The length is asked for on its own, because measuring the field by
        // copying it is the whole of the cost being avoided here.
        if let units = characterCount(of: field), units > Self.maximumUnits {
            guard caret.location <= units else { return .unavailable("range:bounds") }
            // Chromium's container element, described below.  In a field this
            // long a caret at the very start is far more likely to be that than
            // the truth.
            guard caret.location > 0 else { return .unavailable("range:zero") }
            // The length has already said the whole field is more than a read
            // can afford, so an app that will not serve a range is not offered
            // a second chance to hand the whole of it over.
            guard let window = windowBeforeCaret(in: field, caret: caret.location) else {
                return .unavailable("noRange")
            }
            return window
        }
        return wholeField(of: field, caret: caret.location)
    }

    /// Everything in front of the caret, for a field short enough that copying
    /// it whole beats a second round trip.  It is also the only path open to an
    /// app that publishes no length of its own.
    private func wholeField(of field: AXUIElement, caret: Int) -> FocusedCaretText {
        let value: (value: String?, error: AXError) = copy(kAXValueAttribute, from: field)
        guard let text = value.value else { return .unavailable(label("value", value.error)) }
        let whole = text as NSString
        guard whole.length <= Self.maximumUnits else { return .unavailable("tooLong") }
        guard caret <= whole.length else { return .unavailable("range:bounds") }
        // Chromium, and so every Electron app, hands back a container element
        // for a contenteditable every so often, and a container does not track
        // the caret: it answers {0, 0} while its value holds the whole field.
        // Read as truth that says the whole field sits behind the caret, which
        // is indistinguishable from the field having been emptied.  A caret
        // genuinely at the start has nothing in front of it for a delete key to
        // take, so refusing both costs nothing and the next read gets the real
        // element.
        guard caret > 0 || whole.length == 0 else { return .unavailable("range:zero") }
        return .split(head: whole.substring(to: caret), reachesStart: true)
    }

    /// The last `maximumUnits` characters before the caret, asked for by range
    /// so the copy does not grow with the document.  Nil when the app will not
    /// serve one, which leaves the whole-field read to answer or to refuse.
    private func windowBeforeCaret(in field: AXUIElement, caret: Int) -> FocusedCaretText? {
        let start = max(0, caret - Self.maximumUnits)
        var wanted = CFRange(location: start, length: caret - start)
        guard let asked = AXValueCreate(.cfRange, &wanted) else { return nil }
        var raw: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            field,
            kAXStringForRangeParameterizedAttribute as CFString,
            asked,
            &raw
        )
        guard error == .success, let text = raw as? String else { return nil }
        // An app that answers with less than was asked for clipped the range at
        // an end this cannot identify, so the window no longer starts where the
        // count says and a word measured against its edge would be a guess.
        guard (text as NSString).length == wanted.length else { return nil }
        return .split(head: text, reachesStart: start == 0)
    }

    /// How long the field is, without copying it.  Nil when the app publishes
    /// no length, which is the signal to fall back to reading it whole.
    private func characterCount(of field: AXUIElement) -> Int? {
        let count: (value: NSNumber?, error: AXError) = copy(kAXNumberOfCharactersAttribute, from: field)
        return count.value?.intValue
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
