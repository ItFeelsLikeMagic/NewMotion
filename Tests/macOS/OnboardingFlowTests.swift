import Foundation
import XCTest
@testable import NewMotion_macOS
@testable import NewMotionShared

/// The first-run flow, driven without a radio, a dialog, or a phone.  The
/// pause before each ask is set to an hour so a test fires it by hand.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    private final class Asks {
        var bluetooth = 0
        var accessibility = 0
        var pairing = 0
        var bluetoothSettings = 0
        var accessibilitySettings = 0
    }

    private func makeFlow(
        delay: Duration = .seconds(3600),
        pairingSettle: Duration = .zero
    ) -> (MacOnboardingFlow, Asks) {
        let asks = Asks()
        let flow = MacOnboardingFlow(
            actions: MacOnboardingActions(
                askBluetooth: { asks.bluetooth += 1 },
                askAccessibility: { asks.accessibility += 1 },
                offerPairing: { asks.pairing += 1 },
                openBluetoothSettings: { asks.bluetoothSettings += 1 },
                openAccessibilitySettings: { asks.accessibilitySettings += 1 }
            ),
            promptDelay: { _ in delay },
            pairingSettle: pairingSettle
        )
        return (flow, asks)
    }

    func testAPairingMadeInTheFlowIsShownForTheHoldBeforeTheEnd() async throws {
        let (flow, _) = makeFlow(pairingSettle: .milliseconds(50))
        flow.begin(with: MacOnboardingInputs(radio: .poweredOn, accessibility: .granted))
        XCTAssertEqual(flow.step, .pair)

        flow.update(MacOnboardingInputs(radio: .poweredOn, accessibility: .granted, pairingProgress: .paired(deviceName: "Phone")))
        XCTAssertEqual(flow.step, .pair)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(flow.step, .done)
    }

    func testAPhonePairedBeforeTheFlowBeganIsNotHeldOn() {
        let (flow, _) = makeFlow(pairingSettle: .seconds(3600))
        flow.begin(with: MacOnboardingInputs(
            radio: .poweredOn,
            accessibility: .granted,
            pairingProgress: .paired(deviceName: "Phone")
        ))
        XCTAssertEqual(flow.step, .done)
    }

    func testEachStepReadsItsStatusFromTheApp() {
        typealias Flow = MacOnboardingFlow
        var inputs = MacOnboardingInputs()

        XCTAssertEqual(Flow.status(for: .bluetooth, inputs: inputs, asked: false), .waitingToAsk)
        XCTAssertEqual(Flow.status(for: .bluetooth, inputs: inputs, asked: true), .asking)
        inputs.radio = .poweredOn
        XCTAssertEqual(Flow.status(for: .bluetooth, inputs: inputs, asked: true), .granted)
        inputs.radio = .unauthorized
        XCTAssertEqual(Flow.status(for: .bluetooth, inputs: inputs, asked: true), .blocked(.bluetoothDenied))
        inputs.radio = .poweredOff
        XCTAssertEqual(Flow.status(for: .bluetooth, inputs: inputs, asked: true), .blocked(.bluetoothOff))
        inputs.radio = .unsupported
        XCTAssertEqual(Flow.status(for: .bluetooth, inputs: inputs, asked: false), .blocked(.bluetoothUnsupported))

        // A fresh install reads as denied before anyone has asked; that only
        // becomes a problem to show once the dialog has been put up.
        inputs.accessibility = .denied
        XCTAssertEqual(Flow.status(for: .accessibility, inputs: inputs, asked: false), .waitingToAsk)
        XCTAssertEqual(Flow.status(for: .accessibility, inputs: inputs, asked: true), .blocked(.accessibilityMissing))
        inputs.accessibility = .granted
        XCTAssertEqual(Flow.status(for: .accessibility, inputs: inputs, asked: false), .granted)

        inputs.pairingProgress = .waitingForScan
        XCTAssertEqual(Flow.status(for: .pair, inputs: inputs, asked: false), .waitingToAsk)
        XCTAssertEqual(Flow.status(for: .pair, inputs: inputs, asked: true), .asking)
        inputs.pairingProgress = .failed
        XCTAssertEqual(Flow.status(for: .pair, inputs: inputs, asked: true), .blocked(.pairingFailed))
        inputs.pairingProgress = .paired(deviceName: "Phone")
        XCTAssertEqual(Flow.status(for: .pair, inputs: inputs, asked: true), .granted)
    }

    func testTheFlowWalksFromBluetoothToPairedAsEachIsGranted() {
        let (flow, asks) = makeFlow()
        var finished = 0
        flow.onFinished = { finished += 1 }
        var inputs = MacOnboardingInputs(radio: .unknown, accessibility: .denied, pairingProgress: .waitingForLink)

        flow.begin(with: inputs)
        XCTAssertEqual(flow.step, .bluetooth)
        XCTAssertEqual(flow.status, .waitingToAsk)
        XCTAssertEqual(asks.bluetooth, 0)

        flow.promptNow()
        XCTAssertEqual(asks.bluetooth, 1)
        XCTAssertEqual(flow.status, .asking)

        inputs.radio = .poweredOn
        inputs.pairingProgress = .scanning
        flow.update(inputs)
        XCTAssertEqual(flow.step, .accessibility)
        XCTAssertEqual(flow.status, .waitingToAsk)

        flow.promptNow()
        XCTAssertEqual(asks.accessibility, 1)
        XCTAssertEqual(flow.status, .blocked(.accessibilityMissing))
        flow.openSettings()
        XCTAssertEqual(asks.accessibilitySettings, 1)

        inputs.accessibility = .granted
        flow.update(inputs)
        XCTAssertEqual(flow.step, .pair)
        XCTAssertEqual(flow.status, .waitingToAsk)

        flow.promptNow()
        XCTAssertEqual(asks.pairing, 1)
        inputs.pairingProgress = .waitingForScan
        flow.update(inputs)
        XCTAssertEqual(flow.status, .asking)

        inputs.pairingProgress = .paired(deviceName: "Phone")
        flow.update(inputs)
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(finished, 1)
    }

    func testADeniedRadioShowsTheRecoveryAndOpensBluetoothSettings() {
        let (flow, asks) = makeFlow()
        flow.begin(with: MacOnboardingInputs())
        flow.promptNow()
        flow.update(MacOnboardingInputs(radio: .unauthorized))
        XCTAssertEqual(flow.step, .bluetooth)
        XCTAssertEqual(flow.status, .blocked(.bluetoothDenied))
        XCTAssertFalse(MacOnboardingProblem.bluetoothDenied.canRetry)

        flow.openSettings()
        XCTAssertEqual(asks.bluetoothSettings, 1)
        XCTAssertEqual(asks.accessibilitySettings, 0)
    }

    func testAFailedPairingCanBeTriedAgain() {
        let (flow, asks) = makeFlow()
        flow.begin(with: MacOnboardingInputs(radio: .poweredOn, accessibility: .granted, pairingProgress: .scanning))
        XCTAssertEqual(flow.step, .pair)
        flow.promptNow()
        flow.update(MacOnboardingInputs(radio: .poweredOn, accessibility: .granted, pairingProgress: .failed))
        XCTAssertEqual(flow.status, .blocked(.pairingFailed))
        XCTAssertTrue(MacOnboardingProblem.pairingFailed.canRetry)

        flow.promptNow()
        XCTAssertEqual(asks.pairing, 2)
    }

    /// Running the flow again on a Mac that is already set up asks nothing.
    func testStepsAlreadyGrantedAreSkipped() {
        let (flow, asks) = makeFlow()
        var finished = 0
        flow.onFinished = { finished += 1 }
        flow.begin(with: MacOnboardingInputs(
            radio: .poweredOn,
            accessibility: .granted,
            pairingProgress: .paired(deviceName: "Phone")
        ))
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(asks.bluetooth + asks.accessibility + asks.pairing, 0)
    }

    func testThePauseFiresTheAskOnItsOwn() async throws {
        let (flow, asks) = makeFlow(delay: .milliseconds(1))
        flow.begin(with: MacOnboardingInputs())
        XCTAssertEqual(asks.bluetooth, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(asks.bluetooth, 1)
        XCTAssertEqual(flow.status, .asking)
    }

    func testClosingCancelsThePendingAsk() async throws {
        let (flow, asks) = makeFlow(delay: .milliseconds(1))
        flow.begin(with: MacOnboardingInputs())
        flow.cancel()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(asks.bluetooth, 0)
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A Mac set up on an earlier run gets its radio at launch, as it always
    /// has.  A fresh install waits for the flow to ask.
    func testASetUpMacBringsBluetoothUpAtLaunch() throws {
        let defaults = try scratchDefaults()
        defaults.set(true, forKey: "onboardingCompleted")
        let adapter = FakeCentralAdapter()
        let model = MacRemoteAppModel(centralAdapter: adapter, defaults: defaults)
        XCTAssertTrue(model.onboardingCompleted)
        XCTAssertEqual(adapter.activateCount, 1)
    }

    func testAFreshInstallWaitsForTheFlowToAskForBluetooth() throws {
        let defaults = try scratchDefaults()
        let adapter = FakeCentralAdapter()
        let model = MacRemoteAppModel(centralAdapter: adapter, defaults: defaults)
        XCTAssertFalse(model.onboardingCompleted)
        XCTAssertEqual(adapter.activateCount, 0)

        model.requestBluetoothPermission()
        XCTAssertEqual(adapter.activateCount, 1)
    }
}
