import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared

/// Anything that can put a remote command through the safety policy.  The
/// scrub owns no injection path of its own, so a test can watch what it asks
/// for without a window server.
public protocol RemoteInputSubmitting: AnyObject {
    @discardableResult
    func submit(_ command: RemoteInputCommand) -> InputInjectionResult
}

extension SafeInputInjector: RemoteInputSubmitting {}

/// Holds one press of a delete key so the text it rubbed out can come back.
///
/// The phone sends notches; it has no idea what is in the field.  So the field
/// is read once, as the press starts erasing, and every notch after that is
/// served from that one reading: a notch works out how much of the tail it
/// wants, presses Delete exactly that many times, and remembers the characters
/// it took.  Restoring types the last of them back.  Lifting the key throws the
/// memory away, because by then the field may have moved on.
///
/// The Mac decides where a word ends rather than pressing Option and Delete and
/// asking the app afterwards.  Asking is what an app has to answer honestly,
/// and Electron does not: Chromium hands back a container element for a
/// contenteditable, and a container reports the caret at the start of the text
/// however far along it really is, which reads exactly like a field that was
/// emptied.  Counting its own plain Delete presses is the one measurement no
/// app can get wrong, so the whole class of question disappears.  The cost is a
/// word rule of its own, close to a Mac text field's, and about 20 ms per
/// character in the key queue.
///
/// A slide that runs past the start of the text presses nothing at all, so
/// overshooting is free and everything it did erase still comes back.
///
/// When the field cannot be read there is nothing to count from, so a notch
/// falls back to the plain key the phone would have tapped and there is nothing
/// to restore.  Secure input is exactly that case: it is never read from and
/// never typed into.
public final class DeleteScrubCoordinator {
    /// What one notch falls back to for a field this could not read.
    private static let blindHotkey: [DeleteScrubGranularity: MacAllowedHotkey] = [
        .character: .deleteBackward,
        .word: .deleteWordBackward
    ]
    /// A field that will not answer costs a quarter second of the main actor
    /// per read, and that actor also carries every arriving BLE frame.  Only
    /// failures count against this, and Electron needs several of them: its
    /// accessibility tree is still being built as a press begins.
    private static let maximumFailedReads = 6
    /// Enough of a slide to see its shape without a press growing without end.
    private static let maximumTrail = 40
    /// Presses one notch may ask for, matching `InputPolicyLimits.maxHotkeyRun`
    /// so a run this builds is never the thing the policy turns down.  Longer
    /// than any word; a notch that hits it simply takes the first 64.
    private static let maximumRun = 64

    private let submitter: RemoteInputSubmitting
    private let focusedText: FocusedTextReading?
    private let isSecureInputActive: @Sendable () -> Bool

    /// The text in front of the caret that this press has not erased yet.
    private var remaining: [Character] = []
    /// True once the field has answered.  Kept apart from `remaining` being
    /// empty, which is the ordinary state of a press that erased everything.
    private var hasSnapshot = false
    /// What each notch took, newest last.  Restoring walks back along it, so a
    /// notch always gives back exactly what its own delete took.
    private var removed: [String] = []
    /// Set when there is nothing to count from.  Erasing goes on blind;
    /// restoring does not happen at all.
    private var isBlind = false
    private var failedReads = 0
    /// What each notch of the last press did, for the debug surface.  Counts
    /// and outcomes only; field text never appears here.
    private var trail: [String] = []
    /// Why the field could not be read, in the reader's own words.
    private var readFailure = ""

    public init(
        submitter: RemoteInputSubmitting,
        focusedText: FocusedTextReading? = nil,
        isSecureInputActive: @escaping @Sendable () -> Bool = SecureInput.isActive
    ) {
        self.submitter = submitter
        self.focusedText = focusedText
        self.isSecureInputActive = isSecureInputActive
    }

    /// Every notch of the last press, oldest first.  Outlives the press so a
    /// slide can be read back from `/state` once the finger has lifted.
    public var lastSlide: String { trail.joined(separator: " ") }

    /// A short label for the debug surface.  It names counts and outcomes only;
    /// field text never appears here.
    @discardableResult
    public func handle(_ payload: DeleteScrubPayload) -> String {
        let outcome = apply(payload)
        trail.append(outcome)
        if trail.count > Self.maximumTrail { trail.removeFirst() }
        return outcome
    }

    private func apply(_ payload: DeleteScrubPayload) -> String {
        switch payload.phase {
        case .begin:
            reset()
            trail = []
            // An Electron field answers nothing until its accessibility tree
            // has been asked for and built.  The slide is the head start.
            focusedText?.prepare()
            return "deleteScrub begin"
        case .delete:
            return delete(payload.granularity)
        case .restore:
            return restore()
        case .end:
            reset()
            return "deleteScrub end"
        }
    }

    /// Called when the link drops, so a press whose `end` never arrived cannot
    /// restore its text into whatever the next session is pointed at.
    public func abandon() {
        reset()
    }

    private func delete(_ granularity: DeleteScrubGranularity) -> String {
        if !hasSnapshot, !isBlind { takeSnapshot() }
        // Either the budget is spent or this one read did not answer.  A notch
        // with nothing to count from still has to erase something.
        guard hasSnapshot else { return blindDelete(granularity) }

        let length = min(Self.runLength(in: remaining, granularity: granularity), Self.maximumRun)
        // Past the start of the text.  Pressing nothing is what makes an
        // overshoot free: the notches already taken are still restorable.
        guard length > 0 else { return "deleteScrub delete start" }
        guard deleteBackward(length) else { return "deleteScrub delete failed" }
        removed.append(String(remaining.suffix(length)))
        remaining.removeLast(length)
        return "deleteScrub delete \(length)"
    }

    private func restore() -> String {
        // Secure input can come on mid-press, so the typing side is guarded as
        // well as the reading side.
        guard !isSecureInputActive() else { return "deleteScrub restore secure" }
        guard let run = removed.last else {
            return isBlind ? "deleteScrub restore blind:\(readFailure)" : "deleteScrub nothing to restore"
        }
        guard submitter.submit(.text(run)) == .applied else {
            return "deleteScrub restore failed"
        }
        removed.removeLast()
        remaining.append(contentsOf: run)
        return "deleteScrub restore \(run.count)"
    }

    /// No reading to count from, so the notch becomes the key a plain tap would
    /// have sent and the app decides what it takes.  Nothing knows what left,
    /// so nothing is restorable.
    private func blindDelete(_ granularity: DeleteScrubGranularity) -> String {
        guard let hotkey = Self.blindHotkey[granularity],
              submitter.submit(.hotkey(hotkey)) == .applied else {
            return "deleteScrub delete failed"
        }
        return "deleteScrub delete blind:\(readFailure)"
    }

    /// The text in front of the caret before this press erases anything.  A
    /// read that does not answer is not fatal: the next notch tries again,
    /// which is what an Electron tree still being built needs.  Running out of
    /// tries is what ends it.
    private func takeSnapshot() {
        guard let focusedText, !isSecureInputActive() else {
            readFailure = focusedText == nil ? "noReader" : "secure"
            isBlind = true
            return
        }
        let answer = focusedText.textAroundCaret()
        guard case let .split(head, _) = answer else {
            readFailure = answer.label
            failedReads += 1
            if failedReads >= Self.maximumFailedReads { isBlind = true }
            return
        }
        guard !head.isEmpty else {
            readFailure = "emptyField"
            isBlind = true
            return
        }
        remaining = Array(head)
        hasSnapshot = true
    }

    private func deleteBackward(_ count: Int) -> Bool {
        submitter.submit(.hotkeyRun(.deleteBackward, times: count)) == .applied
    }

    private func reset() {
        remaining = []
        hasSnapshot = false
        removed = []
        isBlind = false
        failedReads = 0
        readFailure = ""
    }

    /// How many characters at the end of `text` one notch takes.  Trailing
    /// spaces go with the word in front of them, and a word stops at
    /// punctuation, which is what Option and Delete does in a Mac text field:
    /// `foo.bar` gives up `bar` and leaves the dot.
    static func runLength(in text: [Character], granularity: DeleteScrubGranularity) -> Int {
        guard !text.isEmpty else { return 0 }
        switch granularity {
        case .character:
            return 1
        case .word:
            var index = text.count
            while index > 0, text[index - 1].isWhitespace { index -= 1 }
            guard index > 0 else { return text.count }
            let wantsWord = isWord(text[index - 1])
            while index > 0, !text[index - 1].isWhitespace, isWord(text[index - 1]) == wantsWord {
                index -= 1
            }
            return text.count - index
        }
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
#endif
