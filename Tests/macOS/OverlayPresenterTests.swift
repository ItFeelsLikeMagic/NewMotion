import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// The whole of what the card shows and when, with no window anywhere near it.
/// Everything timed is fired by hand, so nothing here waits.
@MainActor
final class OverlayPresenterTests: XCTestCase {
    /// Holds the blocks the presenter asked to have run later, so a test can
    /// run the ten-second timeout in no time at all.
    @MainActor
    private final class ManualClock {
        private var pending: [(delay: TimeInterval, work: MacOverlayPresenter.Work)] = []

        var scheduler: MacOverlayPresenter.Scheduler {
            { [self] delay, work in pending.append((delay, work)) }
        }

        /// Runs everything scheduled for that delay, the way a run loop would
        /// once the delay had passed.
        func fire(after delay: TimeInterval) {
            let due = pending.filter { $0.delay == delay }
            pending.removeAll { $0.delay == delay }
            for item in due { item.work() }
        }

        /// Runs only the oldest of them: two partials in a row leave two
        /// timeouts pending, and the first one's deadline comes first.
        func fireOldest(after delay: TimeInterval) {
            guard let index = pending.firstIndex(where: { $0.delay == delay }) else { return }
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
            schedule: clock.scheduler,
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

        clock.fire(after: MacOverlayPresenter.hintDuration)
        XCTAssertEqual(presenter.content, .nothing)
    }

    func testAPickerThatIsNeverEndedTimesOutAndUnfreezesTheCursor() {
        let (presenter, clock) = make()
        presenter.beginPicker()
        presenter.highlight(.find)
        clock.fire(after: MacOverlayPresenter.pickerTimeout)
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
        clock.fireOldest(after: MacOverlayPresenter.pickerTimeout)
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
        clock.fire(after: MacOverlayPresenter.transcriptIdleTimeout)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// Each partial pushes the idle timeout out again, so a sentence that keeps
    /// arriving stays up.
    func testAFreshPartialOutlivesTheTimeoutOfTheOneBeforeIt() {
        let (presenter, clock) = make()
        presenter.showTranscript("some")
        presenter.showTranscript("some words")
        clock.fireOldest(after: MacOverlayPresenter.transcriptIdleTimeout)
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
}
