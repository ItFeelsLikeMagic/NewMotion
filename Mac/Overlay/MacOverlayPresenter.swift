import Foundation

#if canImport(NewMotionShared)
import NewMotionShared

/// What the card on the Mac screen is showing right now.
public enum MacOverlayContent: Equatable, Sendable {
    case nothing
    /// A picker is open. `cell` is the lit one, absent until a finger moves.
    case picker(cell: HotkeyAction?)
    /// The words the phone is hearing, on their way to being typed.
    case transcript(String)
    case hint(String)
}

/// Decides what belongs on the card and when it goes away.
///
/// Three things share one piece of glass and only one can be on it: a picker
/// beats a dictation preview, and a preview beats a hint. Keeping that
/// ranking here, away from AppKit, is what lets the whole of it be tested
/// without a window server.
///
/// Everything timed is handed to `schedule`, so a test drives the clock
/// instead of sleeping. A scheduled block is tagged with the generation of the
/// thing it was scheduled for and does nothing once that generation has moved
/// on, which is cheaper and less error-prone than cancelling timers.
@MainActor
public final class MacOverlayPresenter {
    public typealias Work = @MainActor @Sendable () -> Void
    public typealias Scheduler = @MainActor @Sendable (TimeInterval, @escaping Work) -> Void

    /// The phone records nothing about a picker, so the watchdog cannot see
    /// one. A phone that suspends mid-press would otherwise leave the card up
    /// and the cursor frozen until the session ends.
    public static let pickerTimeout: TimeInterval = 10
    /// Long enough to read one line, short enough not to be in the way.
    public static let hintDuration: TimeInterval = 2
    /// The preview channel is unreliable, so a lost "clear" must not strand
    /// words on screen. This timeout is the real guarantee; the empty message
    /// only makes the common case instant.
    public static let transcriptIdleTimeout: TimeInterval = 2
    /// Three plain deletes inside this window is someone rubbing a word out
    /// one press at a time, which is exactly who has not found the slide.
    public static let deleteHintPresses = 3
    public static let deleteHintWindow: TimeInterval = 2
    public static let deleteSlideHint = "Hold delete and slide left to erase faster"

    /// Runs a block after a delay. Injected so tests do not wait.
    public static let timerScheduler: Scheduler = { delay, work in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        timer.tolerance = delay / 4
    }

    /// What should be drawn. Only ever assigned when it actually differs, so
    /// a highlight that repeats the lit cell costs no redraw.
    public private(set) var content: MacOverlayContent = .nothing
    public var onChange: ((MacOverlayContent) -> Void)?

    /// Read once per cursor packet: while a picker is up, travel that is
    /// already in flight must not slide the pointer out from under the
    /// shortcut about to be fired.
    public private(set) var isPickerOpen = false

    private let schedule: Scheduler
    private let isSecureInputActive: () -> Bool

    private var litCell: HotkeyAction?
    private var transcript: String?
    private var hint: String?
    private var pickerGeneration: UInt64 = 0
    private var transcriptGeneration: UInt64 = 0
    private var hintGeneration: UInt64 = 0
    /// When the recent plain deletes landed, newest last.
    private var deletePresses: [TimeInterval] = []

    public init(
        schedule: @escaping Scheduler = MacOverlayPresenter.timerScheduler,
        isSecureInputActive: @escaping () -> Bool = SecureInput.isActive
    ) {
        self.schedule = schedule
        self.isSecureInputActive = isSecureInputActive
    }

    public func beginPicker() {
        isPickerOpen = true
        litCell = nil
        let generation = bump(&pickerGeneration)
        schedule(Self.pickerTimeout) { [weak self] in
            self?.endPicker(generation: generation)
        }
        refresh()
    }

    /// The phone aims; this only lights what it named.
    public func highlight(_ cell: HotkeyAction?) {
        guard isPickerOpen else { return }
        litCell = cell
        refresh()
    }

    /// Commit, cancel and timeout all end the same way. What a commit fires is
    /// the dispatch side's business; the card is gone either way.
    public func endPicker() {
        endPicker(generation: pickerGeneration)
    }

    /// The words the phone has heard so far. Empty means clear.
    public func showTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dictation is already held back at a password field; a preview of it
        // has to be too, or a spoken password paints itself on the screen.
        // Checked on every partial, so secure input turning on mid-sentence
        // takes the words that are already up with the next one.
        guard !trimmed.isEmpty, !isSecureInputActive() else {
            clearTranscript()
            return
        }
        transcript = trimmed
        let generation = bump(&transcriptGeneration)
        schedule(Self.transcriptIdleTimeout) { [weak self] in
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
        schedule(Self.hintDuration) { [weak self] in
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
        transcript = nil
        hint = nil
        deletePresses.removeAll()
        _ = bump(&pickerGeneration)
        _ = bump(&transcriptGeneration)
        _ = bump(&hintGeneration)
        refresh()
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
        if isPickerOpen { return .picker(cell: litCell) }
        if let transcript { return .transcript(transcript) }
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
#endif
