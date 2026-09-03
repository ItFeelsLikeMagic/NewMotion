import Foundation
import XCTest
@testable import PhoneRemote_macOS
@testable import PhoneRemoteShared

/// The Mac half of the held delete key: the app's own key erases, and what
/// comes back is measured against the field rather than guessed at.
final class DeleteScrubTests: XCTestCase {
    private final class RecordingSubmitter: RemoteInputSubmitting {
        var commands: [RemoteInputCommand] = []
        var result: InputInjectionResult = .applied

        /// Set to hold the field still on the next measurement, standing in for
        /// keys that have been posted but not applied yet.
        var stalls = 0

        @discardableResult
        func submit(_ command: RemoteInputCommand) -> InputInjectionResult {
            commands.append(command)
            return result
        }

        func waitForPostedInput() {
            if stalls > 0 { stalls -= 1 } else { onDrained?() }
        }

        /// What the app's keys did, applied when the coordinator waits for them.
        var onDrained: (() -> Void)?

        /// The text this was asked to type, in order.
        var typed: [String] {
            commands.compactMap { if case let .text(value) = $0 { return value } else { return nil } }
        }
    }

    /// Stands in for the focused field.  Tests move it the way the app's own
    /// key would, which is the whole point: the coordinator must not assume.
    private final class StubField: FocusedTextReading, @unchecked Sendable {
        private let lock = NSLock()
        private var answer: FocusedText
        private var count = 0

        init(_ text: String) { answer = .text(text) }
        init(unavailable reason: String) { answer = .unavailable(reason) }

        var reads: Int { lock.withLock { count } }

        func set(_ text: String) { lock.withLock { answer = .text(text) } }
        func setUnavailable(_ reason: String) { lock.withLock { answer = .unavailable(reason) } }

        func focusedText() -> FocusedText {
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

    func testACharacterNotchPressesDeleteAndRestoresTheCharacterThatLeft() {
        let field = StubField("hello")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward)])
        field.set("hell")

        coordinator.handle(scrub(.restore))
        XCTAssertEqual(submitter.typed, ["o"])
    }

    func testAWordNotchPressesOptionDeleteOnce() {
        let field = StubField("erase this word ")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteWordBackward)])
    }

    /// The bug this design exists for.  The app's Option and Delete took only
    /// "bar"; the old whitespace guess would have typed the whole "foo.bar"
    /// back and left "foo.foo.bar" in the field.
    func testRestoreTypesWhatTheAppActuallyTookNotWhatAWordRuleWouldGuess() {
        let field = StubField("foo.bar")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        field.set("foo.")

        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["bar"])
    }

    /// The mirror case: the app took more than a word rule would have.
    func testRestoreFollowsAnAppThatTookMoreThanExpected() {
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        field.set("")

        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["one "])
    }

    /// Deleting walks back from the caret, so typing forward from it unwinds
    /// the notches newest first.
    func testNotchesUnwindNewestFirst() {
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))
        field.set("one ")

        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["two ", "three"])
    }

    /// A run of restores trusts its own typing, so only the turn costs a read.
    func testOnlyTheTurnReadsTheField() {
        let field = StubField("one two three")
        let (coordinator, _) = make(field)

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(field.reads, 1, "the snapshot only")
        field.set("one ")

        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(field.reads, 2, "one measurement at the turn")
    }

    func testRestoringMoreThanLeftDoesNothing() {
        let field = StubField("hi")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete))
        field.set("h")

        coordinator.handle(scrub(.restore))
        coordinator.handle(scrub(.restore))
        XCTAssertEqual(submitter.typed, ["i"])
    }

    /// Something other than this press changed the text, so nothing here knows
    /// what is safe to type any more.
    func testAFieldThatIsNoLongerTheFrontOfTheSnapshotGoesBlind() {
        let field = StubField("hello")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete))
        field.set("goodbye")

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)

        // Blind is for the rest of the press: erasing goes on, restoring does not.
        submitter.commands.removeAll()
        field.set("hello")
        coordinator.handle(scrub(.delete))
        coordinator.handle(scrub(.restore))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward)])
    }

    /// A reversal faster than the keys land reads a field that has not moved
    /// yet.  It must put back too little, never too much.
    func testAReversalBeforeTheKeyLandsRestoresNothingYet() {
        let field = StubField("hello")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete))
        // The field still reads "hello": the Delete is queued, not applied.
        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
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

    /// Secure input can come on part way through a press.
    func testSecureInputPartWayThroughDeclinesTheRestore() {
        let secure = Flag()
        let field = StubField("hello")
        let (coordinator, submitter) = make(field, secure: secure)

        coordinator.handle(scrub(.delete))
        field.set("hell")
        secure.raise()

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// A terminal, or a caret in the middle of a paragraph: the key still
    /// erases, it just cannot promise anything back.
    func testAnUnreadableFieldStillErasesAndRestoresNothing() {
        let field = StubField(unavailable: "caretNotAtEnd")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete))
        coordinator.handle(scrub(.delete, .word))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward), .hotkey(.deleteWordBackward)])

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    /// One read that does not answer must not end the slide.  This is what the
    /// owner's trail showed: a single unreadable field on the first turn, and
    /// every restore after it declined.
    func testOneReadThatDoesNotAnswerIsRetriedByTheNextNotch() {
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        field.setUnavailable("value:notText")
        coordinator.handle(scrub(.restore, .word))
        XCTAssertTrue(submitter.typed.isEmpty)

        field.set("one two ")
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["three"])
    }

    /// A field that will not answer costs a quarter second of the main actor
    /// per read, so one press must not pay it on every notch.
    func testAFieldThatWillNotAnswerIsOnlyAskedTwice() {
        let field = StubField(unavailable: "focus:-25212")
        let (coordinator, _) = make(field)

        for _ in 0..<10 { coordinator.handle(scrub(.delete)) }
        XCTAssertEqual(field.reads, 2)

        // A new press starts the budget over.
        coordinator.handle(scrub(.begin))
        coordinator.handle(scrub(.delete))
        XCTAssertEqual(field.reads, 3)
    }

    /// The failure the owner hit.  A read taken while the keys are still in
    /// flight sees the field unchanged, so nothing looks missing.  That
    /// measurement must not be kept, or the whole slide stays quiet.
    func testANotchThatMeasuredTooEarlyIsRetriedByTheNext() {
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field)
        submitter.onDrained = { field.set("one ") }

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))

        // The first turn reads a field the keys have not reached yet.
        submitter.stalls = 1
        coordinator.handle(scrub(.restore, .word))
        XCTAssertTrue(submitter.typed.isEmpty)

        coordinator.handle(scrub(.restore, .word))
        coordinator.handle(scrub(.restore, .word))
        XCTAssertEqual(submitter.typed, ["two ", "three"])
    }

    /// A restore run trusts its own arithmetic, so a read that arrives late
    /// cannot make it type the same words twice.
    func testARunOfRestoresNeverRepeatsAChunk() {
        let field = StubField("one two three")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete, .word))
        coordinator.handle(scrub(.delete, .word))
        field.set("one ")

        for _ in 0..<5 { coordinator.handle(scrub(.restore, .word)) }
        XCTAssertEqual(submitter.typed, ["two ", "three"])
    }

    func testAnEmptyFieldStillSendsTheKey() {
        let (coordinator, submitter) = make(StubField(""))

        coordinator.handle(scrub(.delete))
        XCTAssertEqual(submitter.commands, [.hotkey(.deleteBackward)])
    }

    /// A press cannot restore into the field the next press is pointed at.
    func testEndingThePressForgetsTheSnapshot() {
        let field = StubField("hi")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete))
        field.set("h")
        coordinator.handle(scrub(.end))

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    func testAbandoningThePressForgetsTheSnapshot() {
        let field = StubField("hi")
        let (coordinator, submitter) = make(field)

        coordinator.handle(scrub(.delete))
        field.set("h")
        coordinator.abandon()

        coordinator.handle(scrub(.restore))
        XCTAssertTrue(submitter.typed.isEmpty)
    }

    func testRestoreRunWalksForwardOneNotchAtATime() {
        func run(_ text: String, _ granularity: DeleteScrubGranularity) -> Int {
            DeleteScrubCoordinator.restoreRun(in: Array(text)[...], granularity: granularity)
        }

        XCTAssertEqual(run("two three ", .word), 4)   // "two "
        XCTAssertEqual(run("three", .word), 5)
        XCTAssertEqual(run(" three", .word), 6)       // the leading space comes too
        XCTAssertEqual(run("  ", .word), 2)           // never zero, so a notch always moves
        XCTAssertEqual(run("", .word), 0)
        XCTAssertEqual(run("two three ", .character), 1)
    }

    /// A slice's indices do not start at zero, which is how the coordinator
    /// always calls this.
    func testRestoreRunReadsFromTheFrontOfASlice() {
        let text = Array("one two three")
        XCTAssertEqual(DeleteScrubCoordinator.restoreRun(in: text[4...], granularity: .word), 4)
    }
}
