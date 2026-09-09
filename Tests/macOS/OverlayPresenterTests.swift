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

    /// A card opens on the grid's Cancel cell, which is what no lit cell
    /// means, and a picker that names one lights it instead.
    func testPickerOpensOnCancelLightsACellAndClosesOnCommit() {
        let (presenter, _) = make()
        presenter.beginPicker()
        XCTAssertEqual(presenter.content, .picker(cell: nil))
        XCTAssertTrue(presenter.isPickerOpen)

        presenter.highlight(.save)
        XCTAssertEqual(presenter.content, .picker(cell: .save))

        presenter.highlight(nil)
        XCTAssertEqual(presenter.content, .picker(cell: nil))

        presenter.endPicker()
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertFalse(presenter.isPickerOpen)
    }

    /// The phone says the lit cell again every couple of seconds while the key
    /// is held. Those repeats change nothing on screen and must not redraw it.
    func testHighlightRepeatingTheSameCellDoesNotRedraw() {
        let (presenter, _) = make()
        var draws = 0
        presenter.onChange = { _ in draws += 1 }
        presenter.beginPicker()
        presenter.highlight(nil)
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

    func testAPickerThatGoesSilentTimesOutAndUnfreezesTheCursor() {
        let (presenter, clock) = make()
        presenter.beginPicker()
        presenter.highlight(.find)
        clock.fire(.picker)
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertFalse(presenter.isPickerOpen)
    }

    /// The timeout counts silence, not the length of the press, so someone
    /// reading the card at five seconds keeps it: the deadline set at begin
    /// passes with the card still up, and the one the highlight set is what
    /// finally closes it.
    func testAHighlightPutsTheSilenceTimeoutBackToTheStart() {
        let (presenter, clock) = make()
        presenter.beginPicker()
        presenter.highlight(.save)

        clock.fireOldest(.picker)
        XCTAssertEqual(presenter.content, .picker(cell: .save))
        XCTAssertTrue(presenter.isPickerOpen)

        clock.fire(.picker)
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertFalse(presenter.isPickerOpen)
    }

    /// A heartbeat repeating the lit cell changes nothing on screen and still
    /// has to buy the card another timeout.
    func testAKeepaliveThatChangesNothingStillHoldsTheCardOpen() {
        let (presenter, clock) = make()
        presenter.beginPicker()
        presenter.highlight(.cut)
        var draws = 0
        presenter.onChange = { _ in draws += 1 }

        presenter.highlight(.cut)
        clock.fireOldest(.picker)
        clock.fireOldest(.picker)
        XCTAssertEqual(presenter.content, .picker(cell: .cut))
        XCTAssertEqual(draws, 0)

        clock.fire(.picker)
        XCTAssertEqual(presenter.content, .nothing)
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
        XCTAssertEqual(presenter.content, .transcript("the newest words", armed: .none))

        presenter.beginPicker()
        XCTAssertEqual(presenter.content, .picker(cell: nil))

        presenter.endPicker()
        XCTAssertEqual(presenter.content, .transcript("the newest words", armed: .none))
    }

    /// The talk button going down puts the card up before a word is said, so
    /// an empty preview blanks the words rather than taking the card away.
    func testAnEmptyPreviewLeavesTheCardUpListening() {
        let (presenter, _) = make()
        presenter.showTranscript("")
        XCTAssertEqual(presenter.content, .transcript("", armed: .none))

        presenter.showTranscript("some words")
        presenter.showTranscript("")
        XCTAssertEqual(presenter.content, .transcript("", armed: .none))

        presenter.clearTranscript()
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// The bar under the words is the phone's, so it arrives and leaves with
    /// the previews rather than with anything the Mac decides.
    func testTheArmedBarFollowsThePreviewsAndGoesWithTheCard() {
        let (presenter, _) = make()
        presenter.showTranscript("some words")
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .none))

        presenter.showTranscript("some words", armed: .send)
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .send))

        // The finger slid off Send and onto Cancel without saying anything new.
        presenter.showTranscript("some words", armed: .cancel)
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .cancel))

        presenter.showTranscript("some words")
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .none))

        presenter.showTranscript("", armed: .send)
        XCTAssertEqual(presenter.content, .transcript("", armed: .send))

        presenter.clearTranscript()
        presenter.showTranscript("some words")
        XCTAssertEqual(
            presenter.content,
            .transcript("some words", armed: .none),
            "a cleared card starts the next hold with no bar"
        )
    }

    /// The listening card is kept alive by the phone like any other, so it
    /// goes the same way if the phone falls silent.
    func testTheListeningCardClearsItselfWhenThePhoneFallsSilent() {
        let (presenter, clock) = make()
        presenter.showTranscript("")
        clock.fire(.transcript)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// A password field stops the card going up at all, empty or not.
    func testSecureInputBlocksTheListeningCard() {
        let secure = SecureInputFlag()
        let (presenter, _) = make(secure: secure)
        secure.isOn = true
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
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .none))
    }

    func testSecureInputBlanksThePreviewAndTakesDownOneAlreadyShowing() {
        let secure = SecureInputFlag()
        let (presenter, _) = make(secure: secure)
        presenter.showTranscript("before the password")
        XCTAssertEqual(presenter.content, .transcript("before the password", armed: .none))

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

    // MARK: - The held delete key

    /// A tap is a whole press, begin and end within a few milliseconds. Three
    /// of them in a row would be three flashes of the card, so the card waits
    /// out the open delay before it appears at all.
    func testATapNeverFlashesTheDeleteCard() {
        let (presenter, clock) = make()
        var draws = 0
        presenter.onChange = { _ in draws += 1 }

        presenter.beginDelete(granularity: .character)
        XCTAssertEqual(presenter.content, .nothing)

        presenter.endDelete()
        clock.fire(.deleteOpen)
        XCTAssertEqual(presenter.content, .nothing)
        XCTAssertEqual(draws, 0)
    }

    func testAHeldDeleteKeyShowsItsUnitOnceTheDelayHasPassed() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .character)

        clock.fire(.deleteOpen)
        XCTAssertEqual(presenter.content, .delete(granularity: .character))

        presenter.endDelete()
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// The finger slid up. The card relights on the other unit without the key
    /// having erased anything.
    func testAUnitChangeRelightsTheCard() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .character)
        clock.fire(.deleteOpen)

        presenter.updateDelete(granularity: .word)
        XCTAssertEqual(presenter.content, .delete(granularity: .word))
    }

    /// A notch or a flip is a finger that is plainly still down, so it opens
    /// the card ahead of the delay rather than waiting it out.
    func testANotchInsideTheDelayOpensTheCardStraightAway() {
        let (presenter, _) = make()
        presenter.beginDelete(granularity: .character)

        presenter.updateDelete(granularity: .word)
        XCTAssertEqual(presenter.content, .delete(granularity: .word))
    }

    /// Nothing was held, so a notch belonging to no press has no card to light.
    func testANotchWithNoPressBehindItShowsNothing() {
        let (presenter, _) = make()
        presenter.updateDelete(granularity: .word)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// A phone that suspends mid-press sends no end, and the card would sit
    /// there for the rest of the session.
    func testADeleteThatIsNeverEndedTimesOut() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .word)
        clock.fire(.deleteOpen)
        XCTAssertEqual(presenter.content, .delete(granularity: .word))

        clock.fire(.delete)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// The same unit arriving on every notch is the ordinary case, and it must
    /// not cost a redraw per notch.
    func testNotchesThatRepeatTheSameUnitDoNotRedraw() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .character)
        clock.fire(.deleteOpen)
        var draws = 0
        presenter.onChange = { _ in draws += 1 }

        presenter.updateDelete(granularity: .character)
        presenter.updateDelete(granularity: .character)
        XCTAssertEqual(draws, 0)
    }

    /// The picker is the only card that freezes the cursor, and a held delete
    /// key must not: the phone is still sending notches, not travel.
    func testAPickerOutranksAHeldDeleteKeyAndTheDeleteKeyDoesNotFreezeTheCursor() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .word)
        clock.fire(.deleteOpen)
        XCTAssertFalse(presenter.isPickerOpen)

        presenter.beginPicker()
        XCTAssertEqual(presenter.content, .picker(cell: nil))

        presenter.endPicker()
        XCTAssertEqual(presenter.content, .delete(granularity: .word))
    }

    /// The finger is on the delete key, so words dictated a moment ago are not
    /// what is being looked at, and the hint the gesture teaches is beside the
    /// point while the gesture is happening.
    func testAHeldDeleteKeyOutranksTheTranscriptAndTheHint() {
        let (presenter, clock) = make()
        presenter.showHint(MacOverlayPresenter.deleteSlideHint)
        presenter.showTranscript("some words")

        presenter.beginDelete(granularity: .character)
        clock.fire(.deleteOpen)
        XCTAssertEqual(presenter.content, .delete(granularity: .character))

        presenter.endDelete()
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .none))
    }

    func testDisconnectClearsAHeldDeleteKeyToo() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .word)
        clock.fire(.deleteOpen)

        presenter.clearAll()
        XCTAssertEqual(presenter.content, .nothing)

        // And the press it cleared cannot light the card again from a notch
        // that was already on its way.
        presenter.updateDelete(granularity: .word)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// A press that ended before its watchdog must not take the next one down
    /// with it when that timeout finally comes round.
    func testATimeoutDoesNotCloseADeletePressOpenedAfterIt() {
        let (presenter, clock) = make()
        presenter.beginDelete(granularity: .character)
        presenter.endDelete()
        presenter.beginDelete(granularity: .word)
        presenter.updateDelete(granularity: .word)

        clock.fireOldest(.delete)
        XCTAssertEqual(presenter.content, .delete(granularity: .word))
    }

    /// Someone tuning the look has a card up on purpose. It has to beat a
    /// picker, and it has to outlive a phone connecting or dropping, which is
    /// the one thing on this card that `clearAll` does not take away.
    func testAPreviewOutranksAPickerAndSurvivesClearAll() {
        let (presenter, _) = make()
        presenter.beginPicker()
        presenter.highlight(.cut)

        presenter.preview(.delete(granularity: .word))
        XCTAssertEqual(presenter.content, .delete(granularity: .word))

        presenter.clearAll()
        XCTAssertEqual(presenter.content, .delete(granularity: .word))

        // And nothing but turning it off takes it down again.
        presenter.preview(nil)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// The card goes up on the key, not on the first arrow: the pad is held
    /// before anything has been sent, and that is when the four keys are worth
    /// showing.  Nothing is lit until an arrow has actually landed.
    func testTheArrowCardOpensDarkAndClosesOnTheLift() {
        let (presenter, _) = make()
        presenter.beginArrows()
        XCTAssertEqual(presenter.content, .arrows(lit: nil))
        // Unlike the picker, this one does not freeze the cursor: the pad
        // fires nothing on lift, so travel under it is still wanted.
        XCTAssertFalse(presenter.isPickerOpen)

        presenter.endArrows()
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// Each notch lights its arrow for long enough to be seen and no longer,
    /// so a steady slide reads as separate steps rather than one lit key.
    func testAnArrowLightsAndGoesOutAgainWithTheCardStillUp() {
        let (presenter, clock) = make()
        presenter.beginArrows()
        presenter.noteArrow(.arrowDown)
        XCTAssertEqual(presenter.content, .arrows(lit: .arrowDown))

        clock.fire(.arrowLit)
        XCTAssertEqual(presenter.content, .arrows(lit: nil))

        presenter.noteArrow(.arrowRight)
        XCTAssertEqual(presenter.content, .arrows(lit: .arrowRight))
    }

    /// A second notch buys the light a full blink of its own, so a run of
    /// arrows does not go dark on the first one's deadline.
    func testTheBlinkOfOneArrowDoesNotPutOutTheNextOne() {
        let (presenter, clock) = make()
        presenter.beginArrows()
        presenter.noteArrow(.arrowLeft)
        presenter.noteArrow(.arrowLeft)

        clock.fireOldest(.arrowLit)
        XCTAssertEqual(presenter.content, .arrows(lit: .arrowLeft))

        clock.fire(.arrowLit)
        XCTAssertEqual(presenter.content, .arrows(lit: nil))
    }

    /// An arrow with no pad behind it is someone tapping an arrow key, and
    /// puts nothing on screen.
    func testAnArrowWithNoPadHeldShowsNothing() {
        let (presenter, _) = make()
        presenter.noteArrow(.arrowUp)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// The heartbeat is another `begin`, because the phone never knows which
    /// arrow the Mac applied.  It must hold the card open without blanking it.
    func testTheHeartbeatHoldsTheArrowCardOpenWithoutPuttingTheArrowOut() {
        let (presenter, clock) = make()
        presenter.beginArrows()
        presenter.noteArrow(.arrowUp)

        presenter.beginArrows()
        clock.fireOldest(.arrows)
        XCTAssertEqual(presenter.content, .arrows(lit: .arrowUp))

        clock.fire(.arrows)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// A phone that suspends mid-press sends no lift, and the card would sit
    /// there for the rest of the session.
    func testAnArrowPadThatGoesSilentTimesOut() {
        let (presenter, clock) = make()
        presenter.beginArrows()
        clock.fire(.arrows)
        XCTAssertEqual(presenter.content, .nothing)

        // And the notch already on its way cannot light it again.
        presenter.noteArrow(.arrowUp)
        XCTAssertEqual(presenter.content, .nothing)
    }

    /// The arrows sit with the picker rather than under it: both are a key
    /// being held, and either beats words dictated a moment ago.
    func testTheArrowCardOutranksTheTranscriptAndClearAllTakesItDown() {
        let (presenter, _) = make()
        presenter.showTranscript("some words")
        presenter.beginArrows()
        XCTAssertEqual(presenter.content, .arrows(lit: nil))

        presenter.endArrows()
        XCTAssertEqual(presenter.content, .transcript("some words", armed: .none))

        presenter.beginArrows()
        presenter.clearAll()
        XCTAssertEqual(presenter.content, .nothing)

        // And the press it cleared cannot light the card again.
        presenter.noteArrow(.arrowLeft)
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
