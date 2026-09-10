import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// What the card on the Mac screen is showing right now.
public enum MacOverlayContent: Equatable, Sendable {
    case nothing
    /// A picker is open. `cell` is the lit one, absent until a finger moves.
    case picker(cell: HotkeyAction?)
    /// The arrow pad is held. `lit` is the arrow just sent, which stays lit
    /// only long enough to be seen, so the card is dark between notches.
    case arrows(lit: HotkeyAction?)
    /// A delete key is held. `granularity` is the unit it will take off next.
    case delete(granularity: DeleteScrubGranularity)
    /// The walk key is held. `row` is what its steps are walking through.
    case walk(row: TabWalkRow)
    /// The words the phone is hearing, on their way to being typed. Empty
    /// while the talk button is down and nothing has been said yet. `armed` is
    /// the bar the finger is sitting on, which is what letting go would do.
    case transcript(String, armed: TranscriptPreviewArmed)
    case hint(String)
}

/// The waits the card runs on its own: what takes something down again, and
/// the one that holds a delete card back until a tap has ruled itself out. One
/// of each kind can be outstanding, so a scheduler holds one timer per kind
/// rather than one per message.
public enum MacOverlayTimeout: Hashable, Sendable {
    case picker
    case arrows
    /// The blink of the arrow a notch just sent.
    case arrowLit
    case hint
    case transcript
    case delete
    /// The wait between a delete key going down and its card appearing.
    case deleteOpen
    case walk
    /// The wait between the walk key going down and its card appearing.
    case walkOpen
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
/// Several things share one piece of glass and only one can be on it: the
/// held keys beat a held delete key, a delete key beats a dictation preview,
/// and a preview beats a hint. Keeping that ranking here, away from AppKit, is
/// what lets the whole of it be tested without a window server.
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
    ///
    /// The arrow pad beats the same heartbeat and runs on the same wait, for
    /// the same reason: nothing on the phone records that its card is up.
    public static let pickerSilenceTimeout: TimeInterval = 6
    /// Long enough to catch out of the corner of an eye, short enough that a
    /// steady slide reads as separate steps rather than one lit key.
    public static let arrowLitDuration: TimeInterval = 0.15
    /// Long enough to read one line, short enough not to be in the way.
    public static let hintDuration: TimeInterval = 2
    /// The preview channel is unreliable, so a lost end must not strand the
    /// card on screen. This timeout is the real guarantee; the ended message
    /// only makes the common case instant. The phone repeats its preview
    /// twice a second, silent hold or not, so a card that is still wanted
    /// survives four lost repeats in a row, which is what a busy link costs.
    public static let transcriptIdleTimeout: TimeInterval = 3
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
    /// The walk key runs on the delete key's two waits, for the delete key's
    /// two reasons: a tap is a whole press and must not flash the card, and a
    /// phone that suspends mid-press sends no lift.
    public static let walkOpenDelay = deleteOpenDelay
    public static let walkTimeout = deleteTimeout

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
    private var isArrowsOpen = false
    private var litArrow: HotkeyAction?
    /// Set once the press has waited out `deleteOpenDelay`, or asked for
    /// something that proves the finger is holding. Nil means no card.
    private var deleteUnit: DeleteScrubGranularity?
    /// What the press is set to before its card is allowed on screen.
    private var pendingDeleteUnit: DeleteScrubGranularity?
    /// Set once the press has waited out `walkOpenDelay`, or stepped, which
    /// proves the finger is holding. Nil means no card.
    private var walkRow: TabWalkRow?
    private var pendingWalkRow: TabWalkRow?
    private var transcript: String?
    private var transcriptArmed = TranscriptPreviewArmed.none
    private var hint: String?
    private var pickerGeneration: UInt64 = 0
    private var arrowsGeneration: UInt64 = 0
    private var arrowLitGeneration: UInt64 = 0
    private var transcriptGeneration: UInt64 = 0
    private var hintGeneration: UInt64 = 0
    private var deleteGeneration: UInt64 = 0
    private var walkGeneration: UInt64 = 0
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

    /// The arrow pad went down, and the heartbeat that says it still is. The
    /// phone repeats `begin` rather than sending a lit key, because the arrows
    /// travel as ordinary hotkeys and only the Mac knows which ones landed, so
    /// a repeat must not blank a card that is already up.
    public func beginArrows() {
        armArrowSilence()
        guard !isArrowsOpen else { return }
        isArrowsOpen = true
        litArrow = nil
        refresh()
    }

    /// One arrow has just been applied. It lights briefly, so a slide reads as
    /// a run of separate steps; the card itself stays up until the key lifts.
    public func noteArrow(_ action: HotkeyAction) {
        guard isArrowsOpen else { return }
        litArrow = action
        let generation = bump(&arrowLitGeneration)
        scheduler.schedule(.arrowLit, after: Self.arrowLitDuration) { [weak self] in
            self?.dimArrow(generation: generation)
        }
        refresh()
    }

    /// The lift, or the silence that stands in for one.
    public func endArrows() {
        endArrows(generation: arrowsGeneration)
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

    /// The walk key went down. Armed rather than shown, the way a delete key
    /// is: a tap on this key is the ordinary one-step app flip, and it would
    /// otherwise flash the card every time.
    public func beginWalk(row: TabWalkRow) {
        walkRow = nil
        pendingWalkRow = row
        armWalk()
        refresh()
    }

    /// A step, or the finger changing which row it walks. Either one is a
    /// finger plainly still down, so it opens the card ahead of the delay
    /// rather than waiting it out.
    public func updateWalk(row: TabWalkRow) {
        guard walkRow != nil || pendingWalkRow != nil else { return }
        pendingWalkRow = nil
        walkRow = row
        armWalk()
        refresh()
    }

    /// The lift, however it came: a commit, a cancel, or the silence that
    /// stands in for one. A press that never opened its card leaves nothing.
    public func endWalk() {
        endWalk(generation: walkGeneration)
    }

    /// The words the phone has heard so far, none of them yet while the talk
    /// button is down and nobody has spoken. Empty puts the card up listening
    /// rather than taking it down; `clearTranscript` is the only way down.
    /// `armed` says which bar the finger is over, so the card can show what
    /// letting go would do.
    public func showTranscript(_ text: String, armed: TranscriptPreviewArmed = .none) {
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
        transcriptArmed = armed
        let generation = bump(&transcriptGeneration)
        scheduler.schedule(.transcript, after: Self.transcriptIdleTimeout) { [weak self] in
            self?.expireTranscript(generation: generation)
        }
        refresh()
    }

    public func clearTranscript() {
        guard transcript != nil else { return }
        transcript = nil
        transcriptArmed = .none
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

    /// A disconnect, a watchdog release, or any lifecycle transition that
    /// takes held input away. Nothing on the card outlives the session it
    /// belongs to.
    public func clearAll() {
        isPickerOpen = false
        litCell = nil
        isArrowsOpen = false
        litArrow = nil
        deleteUnit = nil
        pendingDeleteUnit = nil
        walkRow = nil
        pendingWalkRow = nil
        transcript = nil
        transcriptArmed = .none
        hint = nil
        deletePresses.removeAll()
        _ = bump(&pickerGeneration)
        _ = bump(&arrowsGeneration)
        _ = bump(&arrowLitGeneration)
        _ = bump(&transcriptGeneration)
        _ = bump(&hintGeneration)
        _ = bump(&deleteGeneration)
        _ = bump(&walkGeneration)
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

    /// Starts both of the walk card's waits over: the one that opens it and
    /// the one that gives up on a phone that has gone quiet mid-press.
    private func armWalk() {
        let generation = bump(&walkGeneration)
        scheduler.schedule(.walkOpen, after: Self.walkOpenDelay) { [weak self] in
            self?.openWalk(generation: generation)
        }
        scheduler.schedule(.walk, after: Self.walkTimeout) { [weak self] in
            self?.endWalk(generation: generation)
        }
    }

    private func openWalk(generation: UInt64) {
        guard generation == walkGeneration, let pending = pendingWalkRow else { return }
        pendingWalkRow = nil
        walkRow = pending
        refresh()
    }

    private func endWalk(generation: UInt64) {
        guard generation == walkGeneration else { return }
        guard walkRow != nil || pendingWalkRow != nil else { return }
        walkRow = nil
        pendingWalkRow = nil
        _ = bump(&walkGeneration)
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

    /// Starts the arrow card's silence over. Every arrow-pad message does it,
    /// so the card outlives a thumb that has stopped moving.
    private func armArrowSilence() {
        let generation = bump(&arrowsGeneration)
        scheduler.schedule(.arrows, after: Self.pickerSilenceTimeout) { [weak self] in
            self?.endArrows(generation: generation)
        }
    }

    private func endArrows(generation: UInt64) {
        guard generation == arrowsGeneration, isArrowsOpen else { return }
        isArrowsOpen = false
        litArrow = nil
        _ = bump(&arrowsGeneration)
        _ = bump(&arrowLitGeneration)
        refresh()
    }

    private func dimArrow(generation: UInt64) {
        guard generation == arrowLitGeneration else { return }
        litArrow = nil
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
        if isPickerOpen { return .picker(cell: litCell) }
        // Beside the picker rather than below it: both are a key being held
        // and a card saying what it is doing. It does not freeze the cursor
        // the way the picker does, because the arrow pad fires nothing on
        // lift and the pointer may still be wanted under it.
        if isArrowsOpen { return .arrows(lit: litArrow) }
        // A held key outranks the words: the finger is on the delete key, so
        // whatever was dictated a moment ago is not what is being looked at.
        if let deleteUnit { return .delete(granularity: deleteUnit) }
        // Beside the delete card and below it only because two keys cannot be
        // held by one thumb: whichever card is up, its key is the one under a
        // finger.
        if let walkRow { return .walk(row: walkRow) }
        // Asked on every derivation, not only when a partial arrives, so a
        // redraw for any reason blanks the words. If nothing redraws at all,
        // the 2 second idle timeout is what takes them down.
        if let transcript, !isSecureInputActive() {
            return .transcript(transcript, armed: transcriptArmed)
        }
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
