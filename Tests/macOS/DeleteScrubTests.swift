import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

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

        init(_ head: String, reachesStart: Bool = true) {
            answer = .split(head: head, reachesStart: reachesStart)
        }
        init(unavailable reason: String) { answer = .unavailable(reason) }

        var reads: Int { lock.withLock { count } }

        func set(_ head: String, reachesStart: Bool = true) {
            lock.withLock { answer = .split(head: head, reachesStart: reachesStart) }
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

    /// The spacing between reads is real time, so a test that wants a second
    /// read has to move the clock rather than wait for it.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0

        var reading: TimeInterval { lock.withLock { seconds } }
        func advance(_ by: TimeInterval = 1) { lock.withLock { seconds += by } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isOn: Bool { lock.withLock { value } }
        func raise() { lock.withLock { value = true } }
    }

    private func make(
        _ field: StubField? = nil,
        secure: Flag = Flag(),
        clock: Clock = Clock()
    ) -> (DeleteScrubCoordinator, RecordingSubmitter) {
        let submitter = RecordingSubmitter()
        return (
            DeleteScrubCoordinator(
                submitter: submitter,
                focusedText: field,
                isSecureInputActive: { secure.isOn },
                now: { clock.reading }
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

    /// What the lift sends for notches no reading ever counted.
    private func held(
        _ count: Int,
        _ hotkey: MacAllowedHotkey = .deleteBackward
    ) -> [RemoteInputCommand] {
        [.hotkeyRun(hotkey, times: count)]
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
        coordinator.handle(scrub(.delete))
        XCTAssertTrue(submitter.commands.isEmpty, "nothing goes until the lift")
        XCTAssertEqual(field.reads, 0)

        coordinator.handle(scrub(.end))
        XCTAssertEqual(submitter.commands, held(2))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// The point of holding.  A password field is never read, so a slide back
    /// has nothing to type; it can still take the notch off before the lift
    /// presses anything, which is what stops the count on the phone lying.
    func testSecureInputStillUndoesASlideBack() {
        let secure = Flag()
        secure.raise()
        let (coordinator, submitter) = make(StubField("password"), secure: secure)

        for _ in 0..<5 { coordinator.handle(scrub(.delete)) }
        for _ in 0..<3 { coordinator.handle(scrub(.restore)) }
        coordinator.handle(scrub(.end))

        XCTAssertEqual(submitter.commands, held(2))
    }

    /// A word notch in a password field falls back to the app's own key, which
    /// keeps the count of characters out of this process entirely.
    func testSecureInputErasesAWordWithTheAppsOwnKey() {
        let secure = Flag()
        secure.raise()
        let (coordinator, submitter) = make(StubField("password here"), secure: secure)

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.end, .word))
        XCTAssertEqual(submitter.commands, held(1, .deleteWordBackward))
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
    /// erases, it just waits for the lift and cannot promise anything back.
    func testAnUnreadableFieldErasesAtTheLiftAndRestoresNothing() {
        let clock = Clock()
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25212"), clock: clock)

        coordinator.handle(scrub(.begin))
        for _ in 0..<3 { coordinator.handle(scrub(.delete)); clock.advance() }
        XCTAssertTrue(submitter.commands.isEmpty)

        coordinator.handle(scrub(.end))
        XCTAssertEqual(submitter.commands, held(3))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// The bug this was written for.  In an app that never answers, the old
    /// key erased on every notch and gave nothing back, so a slide out and
    /// most of the way home still took the whole slide off the field.
    func testAnUnreadableFieldNeverErasesMoreThanTheCountSays() {
        let clock = Clock()
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25211"), clock: clock)

        coordinator.handle(scrub(.begin))
        for _ in 0..<11 { coordinator.handle(scrub(.delete)); clock.advance() }
        for _ in 0..<8 { coordinator.handle(scrub(.restore)) }
        coordinator.handle(scrub(.end))

        XCTAssertEqual(submitter.commands, held(3))
    }

    /// A held press longer than one command may carry comes out as whole runs.
    func testHeldNotchesPastTheRunLimitComeOutAsWholeRuns() {
        let limit = InputPolicyLimits().maxHotkeyRun
        let clock = Clock()
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25212"), clock: clock)

        coordinator.handle(scrub(.begin))
        for _ in 0..<(limit + 5) { coordinator.handle(scrub(.delete)); clock.advance() }
        coordinator.handle(scrub(.end))

        XCTAssertEqual(submitter.deletes, limit + 5)
        XCTAssertEqual(submitter.commands.count, 2)
    }

    /// The unit can be slid from characters to words part way through a press,
    /// so a notch that waited has to remember which one it was taken in.
    func testHeldNotchesKeepTheUnitTheyWereTakenIn() {
        let clock = Clock()
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25212"), clock: clock)

        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete, .character)); clock.advance()
        coordinator.handle(scrub(.delete, .word)); clock.advance()
        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.end, .word))

        XCTAssertEqual(submitter.commands, [
            .hotkeyRun(.deleteBackward, times: 1),
            .hotkeyRun(.deleteWordBackward, times: 2)
        ])
    }

    /// A slide up is for the card.  Touching held notches or the snapshot here
    /// would let it rewrite what the press has already taken.
    func testAUnitChangeErasesNothingAndLeavesTheHeldNotchesAlone() {
        let clock = Clock()
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25212"), clock: clock)

        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete, .character)); clock.advance()
        coordinator.handle(scrub(.unitChanged, .word))
        XCTAssertTrue(submitter.commands.isEmpty)

        coordinator.handle(scrub(.end, .word))
        XCTAssertEqual(submitter.commands, held(1))
    }

    /// A press the link never ended cannot erase into whatever comes next.
    func testAbandoningThePressDropsWhatItWasHolding() {
        let (coordinator, submitter) = make(StubField(unavailable: "focus:-25212"))

        coordinator.handle(scrub(.delete))
        coordinator.abandon()
        coordinator.handle(scrub(.end))

        XCTAssertTrue(submitter.commands.isEmpty)
    }

    /// With no reader at all there is nothing to count from, so the lift sends
    /// the key the way a plain tap would.
    func testNoReaderFallsBackToTheKeyAtTheLift() {
        let (coordinator, submitter) = make()

        coordinator.handle(scrub(.delete, .word))
        XCTAssertTrue(submitter.commands.isEmpty)

        coordinator.handle(scrub(.end, .word))
        XCTAssertEqual(submitter.commands, held(1, .deleteWordBackward))
    }

    /// An Electron field answers nothing for the first few asks while its
    /// accessibility tree is still being built, so a refusal costs one notch
    /// rather than the press.
    func testOneReadThatDoesNotAnswerIsRetriedByTheNextNotch() {
        let clock = Clock()
        let field = StubField(unavailable: "range:zero")
        let (coordinator, submitter) = make(field, clock: clock)

        coordinator.handle(scrub(.delete, .word))
        XCTAssertTrue(submitter.commands.isEmpty, "held, not erased blind")

        field.set("one two three")
        clock.advance()
        coordinator.handle(scrub(.delete, .word))

        // The notch that waited is pressed too, oldest first, and both of them
        // are restorable because both were counted.
        XCTAssertEqual(submitter.commands, [deletes(5)[0], deletes(4)[0]])
        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["two ", "three"])
    }

    /// A field that will not answer costs a quarter second of the main actor
    /// per read, so one press must not pay it on every notch.
    func testAFieldThatWillNotAnswerIsOnlyAskedSoManyTimes() {
        let clock = Clock()
        let field = StubField(unavailable: "focus:-25212")
        let (coordinator, _) = make(field, clock: clock)

        for _ in 0..<40 { coordinator.handle(scrub(.delete)); clock.advance() }
        XCTAssertEqual(field.reads, 12)

        // A new press starts the budget over.
        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete))
        XCTAssertEqual(field.reads, 13)
    }

    /// Notches arrive far faster than a wedged field can answer, so the reads
    /// are spaced in time rather than taken one per notch.
    func testReadsAreSpacedRatherThanTakenOnEveryNotch() {
        let clock = Clock()
        let field = StubField(unavailable: "focus:-25212")
        let (coordinator, _) = make(field, clock: clock)

        for _ in 0..<10 { coordinator.handle(scrub(.delete)) }
        XCTAssertEqual(field.reads, 1, "one clock reading, one ask")

        clock.advance(0.5)
        coordinator.handle(scrub(.delete))
        XCTAssertEqual(field.reads, 2)
    }

    /// An empty field is an answer, not a refusal: there is nothing in front of
    /// the caret, so the notch presses nothing and the lift adds nothing.
    func testAnEmptyFieldPressesNothing() {
        let (coordinator, submitter) = make(StubField(""))

        coordinator.handle(scrub(.delete))
        coordinator.handle(scrub(.end))
        XCTAssertTrue(submitter.commands.isEmpty)
    }

    /// A long field is read as a window on to its end.  While a word boundary
    /// sits inside that window the notch is counted exactly as any other.
    func testAWindowOnALongFieldErasesLikeAnyOtherReading() {
        let (coordinator, submitter) = make(StubField("one two three", reachesStart: false))

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, deletes(5))
    }

    /// The far edge of a window is not the start of the text.  A word that runs
    /// up to it may carry on past it, so the notch is held rather than guessed
    /// at, and the lift sends the key the phone would have tapped.
    func testAWordRunningOffTheEdgeOfTheWindowIsHeldForTheLift() {
        let (coordinator, submitter) = make(StubField("three", reachesStart: false))

        coordinator.handle(scrub(.delete, .word))
        XCTAssertTrue(submitter.commands.isEmpty)

        coordinator.handle(scrub(.end))
        XCTAssertEqual(submitter.commands, held(1, .deleteWordBackward))
    }

    /// The same edge, reached by erasing rather than arrived at.  What the
    /// window did hold still went out, and only the notch past it is held.
    func testASlideThatEmptiesTheWindowKeepsWhatItAlreadyErased() {
        let (coordinator, submitter) = make(StubField("one two", reachesStart: false))

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, deletes(3))

        coordinator.handle(scrub(.end))
        XCTAssertEqual(submitter.commands, deletes(3) + held(1, .deleteWordBackward))
    }

    /// A reading that did reach the start keeps the old bargain: sliding past
    /// it presses nothing at all rather than falling back to the app's key.
    func testAWindowThatReachesTheStartStillMakesAnOvershootFree() {
        let (coordinator, submitter) = make(StubField("three"))

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.end))
        XCTAssertEqual(submitter.commands, deletes(5))
    }

    /// The clock moving on is what used to let a second read overwrite the
    /// first.  A field that has not yet taken in the keys already sent to it
    /// answers with characters this has erased, and counting them again erases
    /// them twice.
    func testASuccessfulReadIsNeverTakenAgainMidPress() {
        let clock = Clock()
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field, clock: clock)

        coordinator.handle(scrub(.begin))
        for _ in 0..<3 { coordinator.handle(scrub(.delete, .word)); clock.advance() }

        XCTAssertEqual(field.reads, 1)
        XCTAssertEqual(submitter.deletes, "one two three".count)
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
