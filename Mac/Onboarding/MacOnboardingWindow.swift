#if os(macOS)
import AppKit
import SwiftUI

/// The first-run window.  A non-activating panel rather than a window: on
/// macOS 14 and later an app with no Dock icon is refused activation once a
/// system dialog has handed the front to someone else, so a window that
/// needed the app active stayed behind whatever was in front.  This one
/// floats and takes clicks and keys without the app ever being active.
/// Closing it is the user's way out mid-flow, and the owner is told so the
/// pending ask is cancelled before a dialog can land on an empty desk.
@MainActor
final class MacOnboardingWindow: NSObject, NSWindowDelegate {
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    /// The process that draws the Accessibility prompt.  Its window sits at
    /// the ordinary level, so a floating panel would cover it.
    private static let accessibilityPromptOwner = "universalAccessAuthWarn"

    private var panel: NSPanel?
    private var onClose: (@MainActor () -> Void)?
    private var asideTimer: Timer?
    private var sawPromptOrSettings = false

    /// The Accessibility ask opens its prompt at the ordinary level and
    /// sends the user on to System Settings.  Standing aside puts the panel
    /// at that level too, in front of everything else there, so the prompt
    /// and then Settings can land on top of it.  It stands back up once
    /// both are gone, or when the owner says the step is done.
    var standsAside = false {
        didSet {
            guard standsAside != oldValue else { return }
            sawPromptOrSettings = false
            standsAside ? startWatching() : stopWatching()
            applyLevel()
        }
    }

    func show<Content: View>(_ content: Content, onClose: @escaping @MainActor () -> Void) {
        close()
        self.onClose = onClose
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Up NewMotion"
        // The pane's colour runs edge to edge; only the close button is left
        // of the title bar, and the panel is dragged by its background.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The pastels are light colours with dark text on them, so the
        // panel keeps that look whatever the system appearance is.
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = NSHostingView(rootView: content)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        applyLevel()
        panel.makeKeyAndOrderFront(nil)
    }

    var isShowing: Bool { panel != nil }

    /// A system dialog closing hands the front to whatever had it before;
    /// the panel is floating so it is still in view, and this makes it key
    /// again so the next click or key goes to it.
    func bringToFront() {
        applyLevel()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Programmatic close.  The delegate callback below is for the red
    /// button only, so this is the one path that does not report a close.
    func close() {
        stopWatching()
        onClose = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        let report = onClose
        close()
        report?()
    }

    private func applyLevel() {
        guard let panel else { return }
        if standsAside {
            panel.level = .normal
            // Dropping a level lands the panel behind the other windows
            // there; this puts it at the front of them, where the prompt
            // then covers only it.
            panel.orderFrontRegardless()
        } else {
            panel.level = .floating
        }
    }

    /// Runs only while standing aside, and only on the Accessibility step,
    /// which is before any phone is on the link.  Once the prompt or
    /// Settings has been seen, their absence means the user is done there.
    private func startWatching() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        timer.tolerance = 0.25
        asideTimer = timer
    }

    private func stopWatching() {
        asideTimer?.invalidate()
        asideTimer = nil
    }

    private func watch() {
        let settingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.systemSettingsBundleID
        if settingsInFront || Self.accessibilityPromptIsOnScreen() {
            sawPromptOrSettings = true
        } else if sawPromptOrSettings {
            standsAside = false
        }
    }

    private static func accessibilityPromptIsOnScreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { $0[kCGWindowOwnerName as String] as? String == accessibilityPromptOwner }
    }
}
#endif
