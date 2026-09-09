import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// What the card on the Mac screen is showing right now.
public enum MacOverlayContent: Equatable, Sendable {
    case nothing
    /// A picker is open. `cell` is the lit one, absent until a finger moves.
    case picker(cell: HotkeyAction?)
    /// A delete key is held. `granularity` is the unit it will take off next.
    case delete(granularity: DeleteScrubGranularity)
    /// The words the phone is hearing, on their way to being typed. Empty
    /// while the talk button is down and nothing has been said yet.
    case transcript(String)
    case hint(String)
}

/// The waits the card runs on its own: what takes something down again, and
/// the one that holds a delete card back until a tap has ruled itself out. One
/// of each kind can be outstanding, so a scheduler holds one timer per kind
/// rather than one per message.
public enum MacOverlayTimeout: Hashable, Sendable {
    case picker
    case hint
    case transcript
    case delete
    /// The wait between a delete key going down and its card appearing.
    case deleteOpen
}

/// Runs a block after a delay, at most one outstanding per kind: the newest
/// scheduling of a kind replaces the one before it.
@MainActor
public protocol MacOverlayScheduling: AnyObject {
    func schedule(
        _ kind: MacOverlayTimeout,
        after delay: TimeInterval,
        _ work: @escaping MacOverlayPresenter.Work
    )
}

/// Decides what belongs on the card and when it goes away.
///
/// Four things share one piece of glass and only one can be on it: a picker
/// beats a held delete key, a delete key beats a dictation preview, and a
/// preview beats a hint. Keeping that ranking here, away from AppKit, is what
/// lets the whole of it be tested without a window server.
///
/// Everything timed is handed to the scheduler, so a test drives the clock
/// instead of sleeping. A scheduled block is also tagged with the generation of
/// the thing it was scheduled for, so a block that survives its subject anyway
/// does nothing.
@MainActor
public final class MacOverlayPresenter {
    public typealias Work = @MainActor @Sendable () -> Void

    /// The phone records nothing about a picker, so the watchdog cannot see
    /// one. A phone that suspends mid-press would otherwise leave the card up
    /// and the cursor frozen until the session ends.
    ///
    /// It counts silence, not the length of the press: someone reading the
    /// card before choosing must not have it taken away mid-decision. The
    /// phone says the lit cell again every 2 seconds while the key is held, so
    /// this is three missed heartbeats, which means the phone is gone.
    public static let pickerSilenceTimeout: TimeInterval = 6
    /// Long enough to read one line, short enough not to be in the way.
    public static let hintDuration: TimeInterval = 2
    /// The preview channel is unreliable, so a lost end must not strand the
    /// card on screen. This timeout is the real guarantee; the ended message
    /// only makes the common case instant. The phone repeats its preview
    /// twice a second, silent hold or not, so a card that is still wanted
    /// survives even a lost repeat.
    public static let transcriptIdleTimeout: TimeInterval = 2
    /// Three plain deletes inside this window is someone rubbing a word out
    /// one press at a time, which is exactly who has not found the slide.
    public static let deleteHintPresses = 3
    public static let deleteHintWindow: TimeInterval = 2
    public static let deleteSlideHint = "Hold delete and slide left to erase faster"
    /// The same watchdog reason as the picker: a phone that suspends mid-press
    /// sends no end, and the card would sit there for the rest of the session.
    public static let deleteTimeout: TimeInterval = 10
    /// A tap on the delete key is a whole press: it sends begin and end within
    /// a few milliseconds. Waiting this long before opening means a tap never
    /// flashes the card, while a real hold is still on screen before the finger
    /// has travelled a notch.
    public static let deleteOpenDelay: TimeInterval = 0.15

    /// What should be drawn. Only ever assigned when it actually differs, so
    /// a highlight that repeats the lit cell costs no redraw.
    public private(set) var content: MacOverlayContent = .nothing
    public var onChange: ((MacOverlayContent) -> Void)?

    /// Read once per cursor packet: while a picker is up, travel that is
    /// already in flight must not slide the pointer out from under the
    /// shortcut about to be fired.
    public private(set) var isPickerOpen = false

    private let scheduler: MacOverlayScheduling
    private let isSecureInputActive: () -> Bool

    private var litCell: HotkeyAction?
    /// Set once the press has waited out `deleteOpenDelay`, or asked for
    /// something that proves the finger is holding. Nil means no card.
    private var deleteUnit: DeleteScrubGranularity?
    /// What the press is set to before its card is allowed on screen.
    private var pendingDeleteUnit: DeleteScrubGranularity?
    private var transcript: String?
    private var hint: String?
    /// A card held up while someone tunes the look from the menu bar.
    private var previewContent: MacOverlayContent?
    private var pickerGeneration: UInt64 = 0
    private var transcriptGeneration: UInt64 = 0
    private var hintGeneration: UInt64 = 0
    private var deleteGeneration: UInt64 = 0
    /// When the recent plain deletes landed, newest last.
    private var deletePresses: [TimeInterval] = []

    public init(
        scheduler: MacOverlayScheduling = MacOverlayTimerBank(),
        isSecureInputActive: @escaping () -> Bool = SecureInput.isActive
    ) {
        self.scheduler = scheduler
        self.isSecureInputActive = isSecureInputActive
    }

    public func beginPicker() {
        isPickerOpen = true
        litCell = nil
        armPickerSilence()
        refresh()
    }

    /// The phone aims; this only lights what it named. No cell means the
    /// grid's Cancel cell, which is where a press starts and what a card that
    /// has only just opened is showing.
    public func highlight(_ cell: HotkeyAction?) {
        guard isPickerOpen else { return }
        // Ahead of the redraw guard: a heartbeat that lights the same cell
        // changes nothing on screen and still proves the phone is there.
        armPickerSilence()
        litCell = cell
        refresh()
    }

    /// Commit, cancel and timeout all end the same way. What a commit fires is
    /// the dispatch side's business; the card is gone either way.
    public func endPicker() {
        endPicker(generation: pickerGeneration)
    }

    /// The delete key went down. The card is only armed here, not shown: three
    /// quick taps are three whole presses, and each would flash it.
    public func beginDelete(granularity: DeleteScrubGranularity) {
        deleteUnit = nil
        pendingDeleteUnit = granularity
        let generation = bump(&deleteGeneration)
        scheduler.schedule(.deleteOpen, after: Self.deleteOpenDelay) { [weak self] in
            self?.openDelete(generation: generation)
        }
        scheduler.schedule(.delete, after: Self.deleteTimeout) { [weak self] in
            self?.endDelete(generation: generation)
        }
        refresh()
    }

    /// A notch or a unit flip. Either one is a finger that is plainly still
    /// down, so it opens the card ahead of the delay rather than waiting it
    /// out. Called with the unit the message carried, so a card that missed a
    /// flip is put right by the next notch.
    public func updateDelete(granularity: DeleteScrubGranularity) {
        guard deleteUnit != nil || pendingDeleteUnit != nil else { return }
        pendingDeleteUnit = nil
        deleteUnit = granularity
        refresh()
    }

    /// The key came up, however it came up. A press that never opened its card
    /// leaves nothing behind.
    public func endDelete() {
        endDelete(generation: deleteGeneration)
    }

    /// The words the phone has heard so far, none of them yet while the talk
    /// button is down and nobody has spoken. Empty puts the card up listening
    /// rather than taking it down; `clearTranscript` is the only way down.
    public func showTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dictation is already held back at a password field; a preview of it
        // has to be too, or a spoken password paints itself on the screen.
        // Checked here so the words are not even held, and again in `wanted`
        // so anything that redraws takes down a preview already on screen.
        guard !isSecureInputActive() else {
            clearTranscript()
            return
        }
        transcript = trimmed
        let generation = bump(&transcriptGeneration)
        scheduler.schedule(.transcript, after: Self.transcriptIdleTimeout) { [weak self] in
            self?.expireTranscript(generation: generation)
        }
        refresh()
    }

    public func clearTranscript() {
        guard transcript != nil else { return }
        transcript = nil
        _ = bump(&transcriptGeneration)
        refresh()
    }

    public func showHint(_ text: String) {
        hint = text
        let generation = bump(&hintGeneration)
        scheduler.schedule(.hint, after: Self.hintDuration) { [weak self] in
            self?.expireHint(generation: generation)
        }
        refresh()
    }

    /// Counts the plain deletes arriving from the phone and asks for the hint
    /// once someone has pressed three of them in a row. `now` is passed in so
    /// the run can be tested without waiting one out.
    public func noteDeleteBackward(at now: TimeInterval) {
        deletePresses.removeAll { now - $0 > Self.deleteHintWindow }
        deletePresses.append(now)
        guard deletePresses.count >= Self.deleteHintPresses else { return }
        // Cleared rather than trimmed, so the hint costs another full run
        // instead of repeating on every press after the third.
        deletePresses.removeAll()
        showHint(Self.deleteSlideHint)
    }

    /// Pins a card on screen for as long as the menu bar is tuning the look,
    /// with no timeout of its own: every slider move has to be visible, and a
    /// card that expired mid-drag would hide the thing being adjusted.
    /// `preview(nil)` is the only way down.
    public func preview(_ content: MacOverlayContent?) {
        previewContent = content
        refresh()
    }

    /// A disconnect, a watchdog release, or any lifecycle transition that
    /// takes held input away. Nothing on the card outlives the session it
    /// belongs to.
    ///
    /// The preview is left alone on purpose: it belongs to the popover that is
    /// open, not to the phone session whose held input this is releasing, and
    /// a phone connecting or dropping mid-tune must not clear the screen.
    public func clearAll() {
        isPickerOpen = false
        litCell = nil
        deleteUnit = nil
        pendingDeleteUnit = nil
        transcript = nil
        hint = nil
        deletePresses.removeAll()
        _ = bump(&pickerGeneration)
        _ = bump(&transcriptGeneration)
        _ = bump(&hintGeneration)
        _ = bump(&deleteGeneration)
        refresh()
    }

    private func openDelete(generation: UInt64) {
        guard generation == deleteGeneration, let pending = pendingDeleteUnit else { return }
        pendingDeleteUnit = nil
        deleteUnit = pending
        refresh()
    }

    private func endDelete(generation: UInt64) {
        guard generation == deleteGeneration else { return }
        guard deleteUnit != nil || pendingDeleteUnit != nil else { return }
        deleteUnit = nil
        pendingDeleteUnit = nil
        _ = bump(&deleteGeneration)
        refresh()
    }

    /// Starts the silence over. Every picker message does this, so the card
    /// outlives any decision as long as the phone keeps saying it is there.
    private func armPickerSilence() {
        let generation = bump(&pickerGeneration)
        scheduler.schedule(.picker, after: Self.pickerSilenceTimeout) { [weak self] in
            self?.endPicker(generation: generation)
        }
    }

    private func endPicker(generation: UInt64) {
        guard generation == pickerGeneration, isPickerOpen else { return }
        isPickerOpen = false
        litCell = nil
        _ = bump(&pickerGeneration)
        refresh()
    }

    private func expireTranscript(generation: UInt64) {
        guard generation == transcriptGeneration else { return }
        clearTranscript()
    }

    private func expireHint(generation: UInt64) {
        guard generation == hintGeneration else { return }
        hint = nil
        refresh()
    }

    private func bump(_ generation: inout UInt64) -> UInt64 {
        generation &+= 1
        return generation
    }

    private var wanted: MacOverlayContent {
        // Outranks the phone: someone is looking at this card on purpose.
        if let previewContent {
            // The gate is the same one dictation gets, in case a preview is
            // ever asked for with words in it.
            if case .transcript = previewContent, isSecureInputActive() { return .nothing }
            return previewContent
        }
        if isPickerOpen { return .picker(cell: litCell) }
        // A held key outranks the words: the finger is on the delete key, so
        // whatever was dictated a moment ago is not what is being looked at.
        if let deleteUnit { return .delete(granularity: deleteUnit) }
        // Asked on every derivation, not only when a partial arrives, so a
        // redraw for any reason blanks the words. If nothing redraws at all,
        // the 2 second idle timeout is what takes them down.
        if let transcript, !isSecureInputActive() { return .transcript(transcript) }
        if let hint { return .hint(hint) }
        return .nothing
    }

    private func refresh() {
        let next = wanted
        guard next != content else { return }
        content = next
        onChange?(next)
    }
}

/// The presenter's own timers: one per kind of timeout, replaced rather than
/// piled up, because ten dictation partials a second would otherwise leave ten
/// live timers behind for every one that fires.
///
/// Added to the run loop in `.common` mode on purpose: a menu bar app spends
/// real time tracking its own menu, and `.default` mode stops dead while it
/// does, which would hold the picker open and the cursor frozen behind it.
@MainActor
public final class MacOverlayTimerBank: MacOverlayScheduling {
    private var timers: [MacOverlayTimeout: Timer] = [:]

    public init() {}

    public func schedule(
        _ kind: MacOverlayTimeout,
        after delay: TimeInterval,
        _ work: @escaping MacOverlayPresenter.Work
    ) {
        timers[kind]?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        timer.tolerance = delay / 4
        RunLoop.main.add(timer, forMode: .common)
        timers[kind] = timer
    }

    /// What the test that pins one timer per kind counts.
    public var liveTimers: Int {
        timers.values.filter(\.isValid).count
    }
}
#endif
