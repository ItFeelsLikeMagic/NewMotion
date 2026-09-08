import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

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
/// is read as the press starts, and every notch after that is served from that
/// one reading: a notch works out how much of the tail it wants, presses Delete
/// exactly that many times, and remembers the characters it took.  Restoring
/// types the last of them back.  Lifting the key throws the memory away,
/// because by then the field may have moved on.
///
/// The Mac decides where a word ends rather than pressing Option and Delete and
/// asking the app afterwards.  Asking is what an app has to answer honestly,
/// and Electron does not: Chromium hands back a container element for a
/// contenteditable, and a container reports the caret at the start of the text
/// however far along it really is, which reads exactly like a field that was
/// emptied.  Counting its own plain Delete presses is the one measurement no
/// app can get wrong, so the whole class of question disappears.  The cost is a
/// word rule of its own, close to a Mac text field's.
///
/// A slide that runs past the start of the text presses nothing at all, so
/// overshooting is free and everything it did erase still comes back.
///
/// A notch taken before the field has answered erases nothing.  It is held: the
/// count goes up, a slide back takes one off it, and whatever is still held
/// when the finger lifts goes out then as the plain key the phone would have
/// tapped.  Erasing only at the lift is the one way a slide back can undo
/// something that was never measured, and it is what stops an unreadable app
/// from quietly taking more than the count on the screen says.  It also hands
/// the reading the whole length of the press rather than its first few notches,
/// which is what Chromium needs: its accessibility tree takes about three
/// seconds to build after a client first asks for it.
///
/// Secure input is the case that never resolves: it is never read from, so
/// every notch of that press is held and the lift sends the app's own key.
public final class DeleteScrubCoordinator {
    /// What a held notch falls back to at the lift.
    private static let blindHotkey: [DeleteScrubGranularity: MacAllowedHotkey] = [
        .character: .deleteBackward,
        .word: .deleteWordBackward
    ]
    /// A field that will not answer costs a quarter second of the main actor
    /// per read, and that actor also carries every arriving BLE frame.  Reads
    /// are spaced and counted so one press can only ever spend a moment of it,
    /// while still spanning the seconds an Electron tree takes to build.
    private static let maximumReads = 12
    private static let readGap: TimeInterval = 0.3
    /// Enough of a slide to see its shape without a press growing without end.
    private static let maximumTrail = 40
    /// Presses one command may ask for, matching `InputPolicyLimits.maxHotkeyRun`
    /// so a run this builds is never the thing the policy turns down.  Longer
    /// than any word; a notch that hits it simply takes the first 64.
    private static let maximumRun = 64

    private let submitter: RemoteInputSubmitting
    private let focusedText: FocusedTextReading?
    private let isSecureInputActive: @Sendable () -> Bool
    private let now: @Sendable () -> TimeInterval

    /// The text in front of the caret that this press has not erased yet.
    private var remaining: [Character] = []
    /// True once the field has answered.  Kept apart from `remaining` being
    /// empty, which is the ordinary state of a press that erased everything.
    private var hasSnapshot = false
    /// What each notch took, newest last.  Restoring walks back along it, so a
    /// notch always gives back exactly what its own delete took.
    private var removed: [String] = []
    /// Notches that have pressed nothing yet, because the field had not
    /// answered when they arrived, each with the unit it was taken in.  The
    /// key can be slid from characters to words part way through a press, so a
    /// held notch cannot be told what it meant after the fact.
    private var held: [DeleteScrubGranularity] = []
    private var reads = 0
    private var lastReadAt: TimeInterval?
    /// What each notch of the last press did, for the debug surface.  Counts
    /// and outcomes only; field text never appears here.
    private var trail: [String] = []
    /// Why the field could not be read, in the reader's own words.
    private var readFailure = ""

    public init(
        submitter: RemoteInputSubmitting,
        focusedText: FocusedTextReading? = nil,
        isSecureInputActive: @escaping @Sendable () -> Bool = SecureInput.isActive,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.submitter = submitter
        self.focusedText = focusedText
        self.isSecureInputActive = isSecureInputActive
        self.now = now
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
            // has been asked for and built.  This arrives on the key going
            // down, so the wake has the whole hold before the first notch.
            focusedText?.prepare()
            return "deleteScrub begin"
        case .delete:
            return delete(payload.granularity)
        case .restore:
            return restore()
        case .end:
            let outcome = flush()
            reset()
            return outcome
        }
    }

    /// Called when the link drops, so a press whose `end` never arrived cannot
    /// erase into whatever the next session is pointed at, nor restore into it.
    /// Held notches are dropped rather than pressed, which is the safe half of
    /// holding them in the first place.
    public func abandon() {
        reset()
    }

    private func delete(_ granularity: DeleteScrubGranularity) -> String {
        held.append(granularity)
        takeSnapshotIfDue()
        guard hasSnapshot else { return "deleteScrub delete held \(held.count)" }
        return press()
    }

    /// Presses everything this notch is now able to count, oldest held notch
    /// first.  Until the field answered there was nothing to count against, so
    /// a press that has been waiting comes out here rather than at its notch.
    private func press() -> String {
        var outcome = "deleteScrub delete start"
        while let granularity = held.first {
            let length = min(Self.runLength(in: remaining, granularity: granularity), Self.maximumRun)
            // Past the start of the text.  Pressing nothing is what makes an
            // overshoot free: the notches already taken are still restorable,
            // and the ones still held ask for nothing.
            guard length > 0 else {
                held = []
                return "deleteScrub delete start"
            }
            held.removeFirst()
            guard deleteBackward(length) else { return "deleteScrub delete failed" }
            removed.append(String(remaining.suffix(length)))
            remaining.removeLast(length)
            outcome = "deleteScrub delete \(length)"
        }
        return outcome
    }

    private func restore() -> String {
        // A held notch pressed nothing, so taking one back types nothing.  That
        // makes it the only restore a password field ever gets.
        if removed.isEmpty {
            guard !held.isEmpty else { return "deleteScrub nothing to restore" }
            held.removeLast()
            return "deleteScrub restore held \(held.count)"
        }
        // Secure input can come on mid-press, so the typing side is guarded as
        // well as the reading side.
        guard !isSecureInputActive() else { return "deleteScrub restore secure" }
        guard let run = removed.last, submitter.submit(.text(run)) == .applied else {
            return "deleteScrub restore failed"
        }
        removed.removeLast()
        remaining.append(contentsOf: run)
        return "deleteScrub restore \(run.count)"
    }

    /// The lift.  Whatever is still held never found a reading to count
    /// against, so it goes out now as the key a plain tap would have sent and
    /// the app decides what each press takes.  Nothing knew what left, so
    /// nothing was restorable, and nothing was erased before the count settled.
    private func flush() -> String {
        guard !held.isEmpty else { return "deleteScrub end" }
        let taken = held.count
        var index = 0
        while index < held.count {
            let granularity = held[index]
            var run = 0
            while index < held.count, held[index] == granularity, run < Self.maximumRun {
                run += 1
                index += 1
            }
            guard let hotkey = Self.blindHotkey[granularity],
                  submitter.submit(.hotkeyRun(hotkey, times: run)) == .applied else {
                return "deleteScrub end failed"
            }
        }
        return "deleteScrub end blind:\(taken):\(readFailure)"
    }

    /// The text in front of the caret before this press erases anything.  A
    /// read that does not answer is not fatal: a later notch tries again, which
    /// is what an Electron tree still being built needs.  The tries are spaced
    /// and counted, so an app that never answers cannot spend the press on the
    /// main actor.
    private func takeSnapshotIfDue() {
        guard let focusedText else {
            readFailure = "noReader"
            return
        }
        guard !isSecureInputActive() else {
            readFailure = "secure"
            return
        }
        guard reads < Self.maximumReads else { return }
        let moment = now()
        if let lastReadAt, moment - lastReadAt < Self.readGap { return }
        lastReadAt = moment
        reads += 1

        let answer = focusedText.textAroundCaret()
        guard case let .split(head, _) = answer else {
            readFailure = answer.label
            return
        }
        // An empty head is an answer like any other: there is nothing in front
        // of the caret, so every notch of this press presses nothing.
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
        held = []
        reads = 0
        lastReadAt = nil
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
