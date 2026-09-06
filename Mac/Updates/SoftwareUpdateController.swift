#if os(macOS)
import Foundation
import Sparkle

/// Automatic updates.
///
/// The app asks a signed appcast once a day whether there is a newer build and
/// downloads it in the background. Applying it needs no network: every release
/// is stapled, so the proof Apple notarized it travels inside the file.
///
/// The replacement carries the same Developer ID and bundle identifier, which
/// is what lets the Accessibility grant survive an update. A build signed by
/// anything else would install and then be unable to move the cursor.
///
/// Sparkle installs on quit, and this app is a menu bar item that nobody ever
/// quits. So the staged update is held and applied during a quiet spell
/// instead: no phone authenticated for two minutes running. The swap and
/// relaunch take about a second and cost nothing when no phone is listening.
@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject {
    /// Long enough that someone who walked out of Bluetooth range and came
    /// back is not relaunched mid-use, short enough that an update lands the
    /// same day. Almost always this elapses overnight.
    private static let quietPeriod: TimeInterval = 120

    /// Absent under tests. `xcodebuild test` launches this app as its test
    /// host, and an updater there would reach the network on every run and
    /// could replace the bundle out from under it.
    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater?
    private var readiness: NSKeyValueObservation?

    /// Set once Sparkle has a verified build staged and we have told it we
    /// will choose the moment. Calling it installs and relaunches silently.
    private var pendingInstall: (() -> Void)?
    private var quietTimer: Timer?
    private var phoneIsActive = false

    /// False while a check is already in flight. Sparkle answers a second
    /// request with an alert, which is a poor reply to a double click.
    @Published private(set) var canCheckForUpdates = false

    override init() {
        super.init()
        guard !MacHostRuntime.isInert else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.updater = controller.updater
        canCheckForUpdates = controller.updater.canCheckForUpdates
        readiness = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// The manual path, for someone who does not want to wait for the daily
    /// check. The automatic one needs no help.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Called whenever a phone authenticates or drops. A staged update waits
    /// for the quiet spell to pass without one.
    func phoneSessionChanged(active: Bool) {
        guard phoneIsActive != active else { return }
        phoneIsActive = active
        restartQuietPeriod()
    }

    /// Restarted from scratch on every change, so the two minutes always
    /// measure uninterrupted quiet rather than quiet in total.
    private func restartQuietPeriod() {
        quietTimer?.invalidate()
        quietTimer = nil
        guard pendingInstall != nil, !phoneIsActive else { return }
        quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietPeriod, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.installIfStillQuiet() }
        }
    }

    private func installIfStillQuiet() {
        quietTimer?.invalidate()
        quietTimer = nil
        guard !phoneIsActive, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }
}

extension SoftwareUpdateController: @preconcurrency SPUUpdaterDelegate {
    /// Answering true takes the timing away from Sparkle, which would
    /// otherwise wait for a quit that never comes. Sparkle still installs on
    /// termination if the app happens to be quit first.
    ///
    /// A release marked critical is the exception, and answering false is what
    /// makes the marking mean anything: Sparkle then shows it to the user at
    /// once rather than handing it back to the quiet-period rule, which could
    /// sit on a security fix for as long as a phone stays connected.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        guard !item.isCriticalUpdate else { return false }
        pendingInstall = immediateInstallationBlock
        restartQuietPeriod()
        return true
    }
}
#endif
