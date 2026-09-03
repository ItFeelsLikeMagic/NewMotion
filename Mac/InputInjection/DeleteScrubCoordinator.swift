import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared

/// Anything that can put a remote command through the safety policy.  The
/// scrub owns no injection path of its own, so a test can watch what it asks
/// for without a window server.
public protocol RemoteInputSubmitting: AnyObject {
    @discardableResult
    func submit(_ command: RemoteInputCommand) -> InputInjectionResult

    /// Returns once every key already submitted has reached the window server.
    func waitForPostedInput()
}

extension SafeInputInjector: RemoteInputSubmitting {}

/// Holds one press of a delete key so the text it rubbed out can come back.
///
/// A notch is always the plain key the phone would have tapped, so what leaves
/// is whatever the app in front does with Delete, or with Option and Delete.
/// This never guesses at that amount.  It reads the field once as the press
/// starts erasing, and again the moment the finger turns around; what is
/// missing from that snapshot is exactly what left.  Restoring types the front
/// of the missing text back, which is the most recent notch: deleting walks
/// backwards from the caret, so typing forwards from it unwinds in order.
///
/// Measuring has to wait for the keys.  `submit` hands them to a queue that
/// paces them 10 ms apart and returns straight away, so a fast slide can leave
/// a hundred milliseconds of them still in flight; a read taken then sees the
/// field as it was several notches ago.  So a measurement waits out that queue
/// first, and a measurement that found nothing missing is not kept: the next
/// notch measures again, which is how a slide recovers from a read that was
/// still too early.  A run of restores after a good measurement reads nothing,
/// because by then this knows what it typed.
///
/// This is what stops a press inventing text: every character typed back was in
/// the field before and is not there now.  Anything that does not add up puts
/// the press in blind mode, where notches still erase and restores are
/// declined: a reversal faster than the keys land, an editor that rewrites what
/// it is handed, a hand on the real keyboard.  A field that will not answer at
/// all is blind from the first notch, and so is secure input, which is never
/// read from and never typed into.
public final class DeleteScrubCoordinator {
    /// The key one notch presses: the same key the phone's plain tap sends, so
    /// what a notch erases is whatever that app already does with it.
    private static let notchHotkey: [DeleteScrubGranularity: MacAllowedHotkey] = [
        .character: .deleteBackward,
        .word: .deleteWordBackward
    ]
    /// A field that will not answer costs a quarter second of the main actor
    /// per read, and that actor also carries every arriving BLE frame.  Reads
    /// that answer are cheap, so the budget counts only the ones that fail:
    /// one spare for an Electron tree still building, then the press goes
    /// blind.
    private static let maximumFailedReads = 2
    /// Enough of a slide to see its shape without a press growing without end.
    private static let maximumTrail = 24

    private let submitter: RemoteInputSubmitting
    private let focusedText: FocusedTextReading?
    private let isSecureInputActive: @Sendable () -> Bool

    /// The field as it stood before this press erased anything.
    private var snapshot: [Character] = []
    /// How much of the snapshot the field still holds.  Measured at the last
    /// turn, then kept in step with what this has typed back.
    private var present = 0
    /// True while `present` is this coordinator's own arithmetic rather than a
    /// reading, which is only trustworthy until the next delete.
    private var hasTypedSinceMeasure = false
    /// Set once the sums stop adding up.  Erasing goes on; restoring does not.
    private var isBlind = false
    private var failedReads = 0
    /// What each notch of the last press did, for the debug surface.  Counts
    /// and outcomes only; field text never appears here.
    private var trail: [String] = []
    /// Why the field could not be used, in the reader's own words, so a slide
    /// that would not restore says what stopped it.
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
        // A long slide is a long trail, and only the shape of it is useful.
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
            return restore(payload.granularity)
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
        if snapshot.isEmpty, !isBlind { takeSnapshot() }
        guard let hotkey = Self.notchHotkey[granularity],
              submitter.submit(.hotkey(hotkey)) == .applied else {
            return "deleteScrub delete failed"
        }
        hasTypedSinceMeasure = false
        return isBlind ? "deleteScrub delete blind" : "deleteScrub delete"
    }

    private func restore(_ granularity: DeleteScrubGranularity) -> String {
        guard !isBlind else { return "deleteScrub restore blind:\(readFailure)" }
        // Secure input can come on mid-press, so the typing side is guarded as
        // well as the reading side.
        guard !isSecureInputActive() else {
            isBlind = true
            return "deleteScrub restore secure"
        }
        if !hasTypedSinceMeasure, !measure() { return "deleteScrub restore no:\(readFailure)" }

        let missing = snapshot[present...]
        // Nothing missing, having just been measured, means the keys had not
        // landed yet.  Leaving the measurement unclaimed is what lets the next
        // notch look again instead of the whole slide going quiet.
        guard !missing.isEmpty else { return "deleteScrub restore early" }
        let length = Self.restoreRun(in: missing, granularity: granularity)
        guard submitter.submit(.text(String(missing.prefix(length)))) == .applied else {
            return "deleteScrub restore failed"
        }
        present += length
        hasTypedSinceMeasure = true
        return "deleteScrub restore \(length)"
    }

    /// The field before the press erases anything.  A read that fails is not
    /// fatal: the next notch tries again, which is what an Electron tree still
    /// being built needs.  Running out of reads is what ends it.
    private func takeSnapshot() {
        guard let text = read() else { return }
        guard !text.isEmpty else {
            isBlind = true
            return
        }
        snapshot = text
        present = text.count
    }

    /// Works out how much of the snapshot survived the notches so far.  The
    /// field has to still be the front of the snapshot; anything else means
    /// something other than this press changed the text, and then nothing here
    /// knows what is safe to type.
    private func measure() -> Bool {
        // The keys this press already sent have to be in the field before the
        // field is worth reading.
        submitter.waitForPostedInput()
        guard let text = read() else { return false }
        // Not the front of the snapshot means something other than this press
        // changed the text, and then nothing here knows what is safe to type.
        guard snapshot.starts(with: text) else {
            readFailure = "changed"
            isBlind = true
            return false
        }
        present = text.count
        return true
    }

    /// A read that does not answer is not fatal on its own: the next notch
    /// tries again, which is what an Electron tree still being built needs.
    /// Running out of tries is what ends the press.
    private func read() -> [Character]? {
        guard let focusedText, !isSecureInputActive() else {
            readFailure = focusedText == nil ? "noReader" : "secure"
            isBlind = true
            return nil
        }
        let answer = focusedText.focusedText()
        guard case let .text(value) = answer else {
            readFailure = answer.label
            failedReads += 1
            if failedReads >= Self.maximumFailedReads { isBlind = true }
            return nil
        }
        return Array(value)
    }

    private func reset() {
        snapshot = []
        present = 0
        hasTypedSinceMeasure = false
        isBlind = false
        failedReads = 0
        readFailure = ""
    }

    /// One notch's worth from the front of the missing text: a single
    /// character, or a whole word with the space that trails it, mirroring what
    /// Option and Delete takes going the other way.  A leading space belongs to
    /// the word already back in the field, so it comes along too and no notch
    /// is ever empty.
    static func restoreRun(in text: ArraySlice<Character>, granularity: DeleteScrubGranularity) -> Int {
        guard !text.isEmpty else { return 0 }
        switch granularity {
        case .character:
            return 1
        case .word:
            var length = 0
            while length < text.count, text[text.startIndex + length].isWhitespace { length += 1 }
            while length < text.count, !text[text.startIndex + length].isWhitespace { length += 1 }
            while length < text.count, text[text.startIndex + length].isWhitespace { length += 1 }
            return length
        }
    }
}
#endif
