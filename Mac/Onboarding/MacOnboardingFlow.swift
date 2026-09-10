import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The three things a fresh install has to be given, in the order they are
/// asked for.  Bluetooth goes first because its dialog is the cheaper one:
/// a click, without leaving the app.  Accessibility sends the user to
/// System Settings, and pairing needs both before a phone can be found.
enum MacOnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case bluetooth
    case accessibility
    case pair
    case done

    var next: MacOnboardingStep {
        MacOnboardingStep(rawValue: rawValue + 1) ?? .done
    }
}

/// Why a step is stuck, and what the pane can offer for it.
enum MacOnboardingProblem: Equatable, Sendable {
    case bluetoothDenied
    case bluetoothOff
    case bluetoothUnsupported
    case accessibilityMissing
    case pairingFailed

    /// A Settings button is offered only where a switch exists to flip.
    var opensSettings: Bool {
        switch self {
        case .bluetoothDenied, .bluetoothOff, .accessibilityMissing: return true
        case .bluetoothUnsupported, .pairingFailed: return false
        }
    }

    /// Asking again means something only where the first ask can be redone.
    /// Both permission dialogs appear once per install and both grants are
    /// noticed on their own, so only a failed pairing has a second try.
    var canRetry: Bool { self == .pairingFailed }
}

enum MacOnboardingStepStatus: Equatable, Sendable {
    /// The pane is up and the ask is on its way after a short pause, so the
    /// explanation is read before the dialog covers it.
    case waitingToAsk
    /// The ask has gone out and the answer has not come back.
    case asking
    case granted
    case blocked(MacOnboardingProblem)
}

/// Everything the flow reads from the app.  A value type so a test can hand
/// in any combination without a radio or a phone.
struct MacOnboardingInputs: Equatable, Sendable {
    var radio: BLEPeripheralManagerState = .unknown
    var accessibility: AccessibilityState = .unknown
    var pairingProgress: MacPairingProgress = .idle
}

/// What the flow does to the app: each ask, and each Settings pane.  Injected
/// so the flow can be driven under test without a dialog appearing.
struct MacOnboardingActions {
    var askBluetooth: @MainActor () -> Void
    var askAccessibility: @MainActor () -> Void
    var offerPairing: @MainActor () -> Void
    var openBluetoothSettings: @MainActor () -> Void
    var openAccessibilitySettings: @MainActor () -> Void
}

/// Walks the steps.  The rules that map the app's state to a step's status
/// live in the static functions so they can be checked without a clock.
@MainActor
final class MacOnboardingFlow: ObservableObject {
    /// Long enough to read one paragraph at an easy pace before the system
    /// dialog lands on top of it.  Pairing has no dialog, so its QR code
    /// appears at once.
    nonisolated static func promptDelay(for step: MacOnboardingStep) -> Duration {
        switch step {
        case .bluetooth, .accessibility: return .seconds(3)
        case .pair, .done: return .zero
        }
    }

    /// The handshake finishes faster than an eye can follow, so a pairing
    /// that happened in this flow is shown for at least this long before
    /// the last screen; one that was already done before the flow began
    /// is not shown at all.
    nonisolated static let pairingSettle: Duration = .seconds(1)

    @Published private(set) var step: MacOnboardingStep = .bluetooth
    @Published private(set) var status: MacOnboardingStepStatus = .waitingToAsk
    private(set) var inputs = MacOnboardingInputs()
    /// Called once, when the last step is granted.
    var onFinished: (@MainActor () -> Void)?

    private let actions: MacOnboardingActions
    private let promptDelay: (MacOnboardingStep) -> Duration
    private let pairingSettle: Duration
    private var asked: Set<MacOnboardingStep> = []
    private var promptTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var pairingNeedsSettle = false

    init(
        actions: MacOnboardingActions,
        promptDelay: @escaping (MacOnboardingStep) -> Duration = MacOnboardingFlow.promptDelay(for:),
        pairingSettle: Duration = MacOnboardingFlow.pairingSettle
    ) {
        self.actions = actions
        self.promptDelay = promptDelay
        self.pairingSettle = pairingSettle
    }

    nonisolated static func status(
        for step: MacOnboardingStep,
        inputs: MacOnboardingInputs,
        asked: Bool
    ) -> MacOnboardingStepStatus {
        switch step {
        case .bluetooth:
            switch inputs.radio {
            case .poweredOn: return .granted
            case .unauthorized: return .blocked(.bluetoothDenied)
            case .poweredOff: return .blocked(.bluetoothOff)
            case .unsupported: return .blocked(.bluetoothUnsupported)
            case .unknown, .resetting: return asked ? .asking : .waitingToAsk
            }
        case .accessibility:
            // A fresh install reads as denied before anyone has been asked.
            // Only after the ask does that answer mean the switch is off.
            if inputs.accessibility == .granted { return .granted }
            return asked ? .blocked(.accessibilityMissing) : .waitingToAsk
        case .pair:
            if inputs.pairingProgress.isAuthenticated { return .granted }
            if inputs.pairingProgress == .failed { return .blocked(.pairingFailed) }
            return asked ? .asking : .waitingToAsk
        case .done:
            return .granted
        }
    }

    /// Opens the first step and schedules its ask.  Nothing happens before
    /// this, so a flow can be built and shown before it starts asking.
    func begin(with inputs: MacOnboardingInputs) {
        self.inputs = inputs
        enter(.bluetooth)
        advanceWhileGranted()
    }

    /// The app's state changed.
    func update(_ inputs: MacOnboardingInputs) {
        self.inputs = inputs
        refreshStatus()
        advanceWhileGranted()
    }

    /// A granted step moves on, and so does the next one if it is already
    /// granted: someone who set up once and is running the flow again should
    /// not sit through steps already done.
    private func advanceWhileGranted() {
        while status == .granted, step != .done {
            if step == .pair, pairingNeedsSettle, pairingSettle > .zero {
                settle()
                return
            }
            enter(step.next)
        }
    }

    private func settle() {
        guard settleTask == nil else { return }
        let hold = pairingSettle
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.pairingNeedsSettle = false
            self.advanceWhileGranted()
        }
    }

    /// Fires the current step's ask now, whether the pause is still running
    /// or a failed attempt is being tried again.
    func promptNow() {
        promptTask?.cancel()
        promptTask = nil
        asked.insert(step)
        switch step {
        case .bluetooth: actions.askBluetooth()
        case .accessibility: actions.askAccessibility()
        case .pair: actions.offerPairing()
        case .done: break
        }
        refreshStatus()
    }

    func openSettings() {
        switch step {
        case .bluetooth: actions.openBluetoothSettings()
        case .accessibility: actions.openAccessibilitySettings()
        case .pair, .done: break
        }
    }

    /// Stops a pause that has not fired.  The window closing is the caller,
    /// and a dialog must not appear over whatever the user went to do next.
    func cancel() {
        promptTask?.cancel()
        promptTask = nil
        settleTask?.cancel()
        settleTask = nil
    }

    private func enter(_ next: MacOnboardingStep) {
        cancel()
        step = next
        refreshStatus()
        if next == .pair { pairingNeedsSettle = status != .granted }
        if next == .done {
            onFinished?()
            return
        }
        guard status == .waitingToAsk else { return }
        let delay = promptDelay(next)
        promptTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.step == next else { return }
            self.promptNow()
        }
    }

    private func refreshStatus() {
        let next = Self.status(for: step, inputs: inputs, asked: asked.contains(step))
        if next != status { status = next }
    }
}
