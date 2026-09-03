import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

/// The Mac half of the held delete key.  It reads the field once, then counts
/// its own plain Delete presses, so what left is known without asking the app.
final class DeleteScrubTests: XCTestCase {
    private final class RecordingSubmitter: RemoteInputSubmitting {
        var commands: [RemoteInputCommand] = []
        var result: InputInjectionResult = .applied

        @discardableResult
        func submit(_ command: RemoteInputCommand) -> InputInjectionResult {
            commands.append(command)
            return result
        }

        /// The text this was asked to type, in order.
        var typed: [String] {
            commands.compactMap { if case let .text(value) = $0 { return value } else { return nil } }
        }

        /// Presses asked for across every run this was handed.
        var deletes: Int {
            commands.reduce(0) {
                if case let .hotkeyRun(.deleteBackward, times) = $1 { return $0 + times }
                return $0
            }
        }
    }

    /// Stands in for the focused field.  Only the snapshot ever asks it, so a
    /// test that changes it mid-press is checking that nothing looks again.
    private final class StubField: FocusedTextReading, @unchecked Sendable {
        private let lock = NSLock()
        private var answer: FocusedCaretText
        private var count = 0

        init(_ head: String, tail: String = "") { answer = .split(head: head, tail: tail) }
        init(unavailable reason: String) { answer = .unavailable(reason) }

        var reads: Int { lock.withLock { count } }

        func set(_ head: String, tail: String = "") {
            lock.withLock { answer = .split(head: head, tail: tail) }
        }

        func setUnavailable(_ reason: String) { lock.withLock { answer = .unavailable(reason) } }

        func focusedText() -> FocusedText { .unavailable("notUsed") }

        func textAroundCaret() -> FocusedCaretText {
            lock.withLock {
                count += 1
                return answer
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isOn: Bool { lock.withLock { value } }
        func raise() { lock.withLock { value = true } }
    }

    private func make(
        _ field: StubField? = nil,
        secure: Flag = Flag()
    ) -> (DeleteScrubCoordinator, RecordingSubmitter) {
        let submitter = RecordingSubmitter()
        return (
            DeleteScrubCoordinator(
                submitter: submitter,
                focusedText: field,
                isSecureInputActive: { secure.isOn }
            ),
            submitter
        )
    }

    private func scrub(
        _ phase: DeleteScrubPhase,
        _ granularity: DeleteScrubGranularity = .character
    ) -> DeleteScrubPayload {
        DeleteScrubPayload(phase: phase, granularity: granularity)
    }

    /// One notch is one command, however many presses it asks for.
    private func deletes(_ count: Int) -> [RemoteInputCommand] {
        [.hotkeyRun(.deleteBackward, times: count)]
    }

    /// The heart of the design.  A word notch is plain Delete, never Option and
    /// Delete, because a count of its own presses is the one thing no app can
    /// answer wrongly.  It is one command carrying the whole run, not a press
    /// per character.  The presses inside a run go out with no spacing, which is
    /// what took a five-letter word from about 100 ms to about one.  Measured
    /// with `/keyburst`: 64 presses at no spacing removed exactly 64
    /// characters, in a native text area and in Chromium alike.
    func testAWordNotchIsOneCommandForTheWholeRun() {
        let (coordinator, submitter) = make(StubField("erase this word"))

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkeyRun(.deleteBackward, times: 4)])
    }

    /// A run longer than the policy allows would be turned down outright, so a
    /// notch never builds one.  Nothing in a language is 64 characters of word.
    func testANotchNeverAsksForMorePressesThanThePolicyAllows() {
        let limit = InputPolicyLimits().maxHotkeyRun
        let (coordinator, submitter) = make(StubField(String(repeating: "a", count: limit + 30)))

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkeyRun(.deleteBackward, times: limit)])

        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, [String(repeating: "a", count: limit)])
    }

    func testACharacterNotchPressesDeleteAndRestoresTheCharacter() {
        let (coordinator, submitter) = make(StubField("hello"))

        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete))
        XCTAssertEqual(submitter.commands, deletes(1))

        coordinator.handle(scrub(.restore))
        XCTAssertEqual(submitter.typed, ["o"])
    }

    /// The trailing space belongs to the word in front of it, so the words come
    /// off one at a time rather than a word then its gap.
    func testAWordTakesTheSpacesBehindItToo() {
        let (coordinator, submitter) = make(StubField("erase this word  "))

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, deletes(6))   // "word  "
    }

    /// The bug that started this.  Nothing is guessed and nothing is measured,
    /// so what comes back is character for character what went.
    func testRestoreGivesBackExactlyWhatTheNotchTook() {
        let (coordinator, submitter) = make(StubField("foo.bar"))

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, deletes(3))   // "bar", the dot stays

        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["bar"])
    }

    /// Deleting walks back from the caret, so typing forward from it unwinds
    /// the notches newest first.
    func testNotchesUnwindNewestFirst() {
        let (coordinator, submitter) = make(StubField("one two three"))

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.restore, .word))

        XCTAssertEqual(submitter.typed, ["two ", "three"])
    }

    /// One reading serves the whole press.  Nothing is asked at the turn, which
    /// is what made this work in an Electron field at all.
    func testThePressReadsTheFieldExactlyOnce() {
        let field = StubField("one two three")
        let (coordinator, _) = make(field)

        coordinator.handle(scrub(.begin))
        for _ in 0..<3 { coordinator.handle(scrub(.delete, .word)) }
        for _ in 0..<3 { coordinator.handle(scrub(.restore, .word)) }

        XCTAssertEqual(field.reads, 1)
    }

    /// A field that moves under a press is not this design's problem, because
    /// nothing looks at it again.  The ledger is what restore trusts.
    func testAFieldThatMovesMidPressDoesNotStopTheSlide() {
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        field.setUnavailable("range:zero")

        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["three"])
    }

    func testRestoringMoreThanLeftDoesNothing() {
        let (coordinator, submitter) = make(StubField("hi"))

        coordinator.handle(scrub(.delete))
        for _ in 0..<4 { coordinator.handle(scrub(.restore)) }

        XCTAssertEqual(submitter.typed, ["i"])
    }

    /// The owner's second bug.  A slide that runs past the start of the text
    /// must cost nothing, and everything it did erase must still come back.
    func testSlidingPastTheStartPressesNothingAndStaysRestorable() {
        let (coordinator, submitter) = make(StubField("one two"))

        for _ in 0..<8 { coordinator.handle(scrub(.delete, .word)) }
        XCTAssertEqual(submitter.deletes, 7, "the text, and not one press more")

        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["one ", "two"])
    }

    func testSecureInputIsNeverReadFromAndStillErases() {
        let secure = Flag()
        secure.raise()
        let field = StubField("password")
        let (coordinator, submitter) = make(field, secure: secure)

        coordinator.handle(scrub(.delete))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward)])
        XCTAssertEqual(field.reads, 0)

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// A word notch in a password field falls back to the app's own key, which
    /// keeps the count of characters out of this process entirely.
    func testSecureInputErasesAWordWithTheAppsOwnKey() {
        let secure = Flag()
        secure.raise()
        let (coordinator, submitter) = make(StubField("password here"), secure: secure)

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteWordBackward)])
    }

    /// Secure input can come on part way through a press.
    func testSecureInputPartWayThroughDeclinesTheRestore() {
        let secure = Flag()
        let (coordinator, submitter) = make(StubField("hello"), secure: secure)

        coordinator.handle(scrub(.delete))
        secure.raise()

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// A terminal, or any field that will not say what is in it: the key still
    /// erases, it just cannot promise anything back.
    func testAnUnreadableFieldStillErasesAndRestoresNothing() {
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25212"))

        coordinator.handle(scrub(.delete))
        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward), .hotkey(.deleteWordBackward)])

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// With no reader at all there is nothing to count from, so the key goes
    /// out the way a plain tap would.
    func testNoReaderFallsBackToTheKey() {
        let (coordinator, submitter) = make()

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteWordBackward)])
    }

    /// An Electron field answers nothing for the first few asks while its
    /// accessibility tree is still being built, so a refusal costs one notch
    /// rather than the press.
    func testOneReadThatDoesNotAnswerIsRetriedByTheNextNotch() {
        let field = StubField(unavailable: "range:zero")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteWordBackward)])

        field.set("one two three")
        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["three"])
    }

    /// A field that will not answer costs a quarter second of the main actor
    /// per read, so one press must not pay it on every notch.
    func testAFieldThatWillNotAnswerIsOnlyAskedSoManyTimes() {
        let field = StubField(unavailable: "focus:-25212")
        let (coordinator, _) = make(field)

        for _ in 0..<20 { coordinator.handle(scrub(.delete)) }
        XCTAssertEqual(field.reads, 6)

        // A new press starts the budget over.
        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete))
        XCTAssertEqual(field.reads, 7)
    }

    /// Nothing in front of the caret to count, so the key goes to the app and
    /// whatever it finds is its business.
    func testAnEmptyFieldStillSendsTheKey() {
        let (coordinator, submitter) = make(StubField(""))

        coordinator.handle(scrub(.delete))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward)])
    }

    /// Text after the caret is no obstacle: only the head is counted from.
    func testTextAfterTheCaretDoesNotStopARestore() {
        let (coordinator, submitter) = make(StubField("one two three", tail: "\nand a second line"))

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["three"])
    }

    /// A press cannot restore into the field the next press is pointed at.
    func testEndingThePressForgetsTheLedger() {
        let (coordinator, submitter) = make(StubField("hi"))

        coordinator.handle(scrub(.delete))
        coordinator.handle(scrub(.end))

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    func testAbandoningThePressForgetsTheLedger() {
        let (coordinator, submitter) = make(StubField("hi"))

        coordinator.handle(scrub(.delete))
        coordinator.abandon()

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// A refused press must not be booked as text that left, or the restore
    /// would put back something still on screen.
    func testARefusedDeleteIsNotRecordedAsRemoved() {
        let (coordinator, submitter) = make(StubField("hello"))
        submitter.result = .failed

        coordinator.handle(scrub(.delete))
        submitter.result = .applied
        coordinator.handle(scrub(.restore))

        XCTAssertTrue(submitter.typed.isEmpty)
    }

    func testTheSlideIsReadableAfterTheFingerLifts() {
        let (coordinator, _) = make(StubField("one two"))

        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.end))

        XCTAssertEqual(
            coordinator.lastSlide,
            "deleteScrub begin deleteScrub delete 3 deleteScrub restore 3 deleteScrub end"
        )
    }

    /// The word rule, which stands in for a Mac text field's own.
    func testTheWordRuleStopsAtSpacesAndPunctuation() {
        func run(_ text: String, _ granularity: DeleteScrubGranularity = .word) -> Int {
            DeleteScrubCoordinator.runLength(in: Array(text), granularity: granularity)
        }

        XCTAssertEqual(run("one two three"), 5)     // "three"
        XCTAssertEqual(run("one two three "), 6)    // "three ", the gap comes too
        XCTAssertEqual(run("one two   "), 6)        // "two   "
        XCTAssertEqual(run("foo.bar"), 3)           // "bar", not the dot
        XCTAssertEqual(run("foo."), 1)              // then the dot on its own
        XCTAssertEqual(run("foo...bar "), 4)        // "bar "
        XCTAssertEqual(run("hello"), 5)
        XCTAssertEqual(run("   "), 3)               // nothing but gap, so take it
        XCTAssertEqual(run(""), 0)
        XCTAssertEqual(run("one two three", .character), 1)
        XCTAssertEqual(run("", .character), 0)
    }
}
