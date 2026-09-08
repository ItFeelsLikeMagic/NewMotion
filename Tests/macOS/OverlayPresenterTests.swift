import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// The whole of what the card shows and when, with no window anywhere near it.
/// Everything timed is fired by hand, so nothing here waits.
@MainActor
final class OverlayPresenterTests: XCTestCase {
    /// Holds the blocks the presenter asked to have run later, so a test can
    /// run the ten-second timeout in no time at all. Unlike the real bank it
    /// keeps every block rather than the newest per kind, so a test can also
    /// fire a stale one and watch the presenter ignore it.
    @MainActor
    private final class ManualClock: MacOverlayScheduling {
        private var pending: [(kind: MacOverlayTimeout, work: MacOverlayPresenter.Work)] = []

        func schedule(
            _ kind: MacOverlayTimeout,
            after delay: TimeInterval,
            _ work: @escaping MacOverlayPresenter.Work
        ) {
            pending.append((kind, work))
        }

        /// Runs everything of that kind, the way a run loop would once the
        /// delay had passed.
        func fire(_ kind: MacOverlayTimeout) {
            let due = pending.filter { $0.kind == kind }
            pending.removeAll { $0.kind == kind }
            for item in due { item.work() }
        }

        /// Runs only the oldest of them: two partials in a row schedule twice,
        /// and the first one's deadline comes first.
        func fireOldest(_ kind: MacOverlayTimeout) {
            guard let index = pending.firstIndex(where: { $0.kind == kind }) else { return }
            let item = pending.remove(at: index)
            item.work()
        }
    }

    @MainActor
    private final class SecureInputFlag {
        var isOn = false
    }

    private func make(
        secure: SecureInputFlag = SecureInputFlag()
    ) -> (MacOverlayPresenter, ManualClock) {
        let clock = ManualClock()
        let presenter = MacOverlayPresenter(
            scheduler: clock,
            isSecureInputActive: { secure.isOn }
        )
        return (presenter, clock)
    }

    func testPickerOpensLightsACellAndClosesOnCommit() {
        let (presenter, _) = make()
        presenter.beginPicker()
        XCTAssertEqual(presenter.content, .picker(cell: nil))
        XCTAssertTrue(presenter.isPickerOpen)

        presenter.highlight(.save)
        XCTAssertEqual(presenter.content, .picker(cell: .save))

        presenter.endPicker()
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertFalse(presenter.isPickerOpen)
    }

    func testHighlightRepeatingTheSameCellDoesNotRedraw() {
        let (presenter, _) = make()
        var draws = 0
        presenter.onChange = { _ in draws += 1 }
        presenter.beginPicker()
        presenter.highlight(.cut)
        presenter.highlight(.cut)
        presenter.highlight(.cut)
        XCTAssertEqual(draws, 2)
    }

    func testPickerOutranksAHintAndTheHintIsWhatIsLeftBehind() {
        let (presenter, clock) = make()
        presenter.showHint(MacOverlayPresenter.deleteSlideHint)
        presenter.beginPicker()
        XCTAssertEqual(presenter.content, .picker(cell: nil))

        presenter.endPicker()
        XCTAssertEqual(presenter.content, .hint(MacOverlayPresenter.deleteSlideHint))

        clock.fire(.hint)
        XCTAssertEqual(presenter.content, .nothing)
    }

    func testAPickerThatIsNeverEndedTimesOutAndUnfreezesTheCursor() {
        let (presenter, clock) = make()
        presenter.beginPicker()
        presenter.highlight(.find)
        clock.fire(.picker)
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertFalse(presenter.isPickerOpen)
    }

    /// A picker that ended before its timeout must not take the next one down
    /// with it when that timeout finally comes round.
    func testATimeoutDoesNotCloseAPickerOpenedAfterIt() {
        let (presenter, clock) = make()
        presenter.beginPicker()
        presenter.endPicker()
        presenter.beginPicker()
        clock.fireOldest(.picker)
        XCTAssertEqual(presenter.content, .picker(cell: nil))
        XCTAssertTrue(presenter.isPickerOpen)
    }

    func testHighlightIsIgnoredWhenNoPickerIsOpen() {
        let (presenter, _) = make()
        presenter.highlight(.copy)
        XCTAssertEqual(presenter.content, .nothing)
    }

    func testPickerBeatsTranscriptAndTranscriptBeatsHint() {
        let (presenter, _) = make()
        presenter.showHint("hold delete")
        presenter.showTranscript("the newest words")
        XCTAssertEqual(presenter.content, .transcript("the newest words"))

        presenter.beginPicker()
        XCTAssertEqual(presenter.content, .picker(cell: nil))

        presenter.endPicker()
        XCTAssertEqual(presenter.content, .transcript("the newest words"))
    }

    func testAnEmptyPreviewClearsTheTranscript() {
        let (presenter, _) = make()
        presenter.showTranscript("some words")
        presenter.showTranscript("")
        XCTAssertEqual(presenter.content, .nothing)
    }

    func testTheTranscriptClearsItselfWhenPartialsStop() {
        let (presenter, clock) = make()
        presenter.showTranscript("some words")
        clock.fire(.transcript)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// Each partial pushes the idle timeout out again, so a sentence that keeps
    /// arriving stays up.
    func testAFreshPartialOutlivesTheTimeoutOfTheOneBeforeIt() {
        let (presenter, clock) = make()
        presenter.showTranscript("some")
        presenter.showTranscript("some words")
        clock.fireOldest(.transcript)
        XCTAssertEqual(presenter.content, .transcript("some words"))
    }

    func testSecureInputBlanksThePreviewAndTakesDownOneAlreadyShowing() {
        let secure = SecureInputFlag()
        let (presenter, _) = make(secure: secure)
        presenter.showTranscript("before the password")
        XCTAssertEqual(presenter.content, .transcript("before the password"))

        secure.isOn = true
        presenter.showTranscript("before the password and more")
        XCTAssertEqual(presenter.content, .nothing)
    }

    func testDisconnectClearsEverything() {
        let (presenter, _) = make()
        presenter.showHint("hold delete")
        presenter.showTranscript("some words")
        presenter.beginPicker()
        presenter.highlight(.paste)

        presenter.clearAll()
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertFalse(presenter.isPickerOpen)
    }

    func testThreeDeletesInARowAskForTheHintAndSlowOnesDoNot() {
        let (presenter, _) = make()
        presenter.noteDeleteBackward(at: 100)
        presenter.noteDeleteBackward(at: 100.3)
        XCTAssertEqual(presenter.content, .nothing)

        presenter.noteDeleteBackward(at: 100.6)
        XCTAssertEqual(presenter.content, .hint(MacOverlayPresenter.deleteSlideHint))

        presenter.clearAll()
        presenter.noteDeleteBackward(at: 200)
        presenter.noteDeleteBackward(at: 210)
        presenter.noteDeleteBackward(at: 220)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// Secure input turning on has to take words that are already up, not wait
    /// for the next partial: anything at all that redraws the card is enough.
    func testSecureInputBlanksAPreviewOnTheNextRedrawWhateverCausedIt() {
        let secure = SecureInputFlag()
        let (presenter, clock) = make(secure: secure)
        presenter.showTranscript("before the password")

        secure.isOn = true
        presenter.showHint("hold delete")
        XCTAssertEqual(presenter.content, .hint("hold delete"))

        clock.fire(.hint)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// Ten partials a second must not leave ten live timers behind, and the
    /// three kinds of timeout must not cancel each other.
    func testTheTimerBankKeepsOneTimerPerKindOfTimeout() {
        let bank = MacOverlayTimerBank()
        for _ in 0..<10 {
            bank.schedule(.transcript, after: 60) {}
        }
        XCTAssertEqual(bank.liveTimers, 1)

        bank.schedule(.picker, after: 60) {}
        bank.schedule(.hint, after: 60) {}
        XCTAssertEqual(bank.liveTimers, 3)
    }
}
