#if os(macOS)
import AppKit
import SwiftUI

/// The pane the card is drawn on, and nothing else. What goes on it, and for
/// how long, is `MacOverlayPresenter`'s business.
///
/// It never takes focus and never takes a click, so the app the user is
/// actually in keeps both. That is load bearing: a card that became key would
/// swallow the keys we are injecting.
@MainActor
final class MacScreenOverlayWindow {
    private static let fadeDuration: TimeInterval = 0.12

    private let shown = MacOverlayContentBox()
    private var panel: NSPanel?
    private var hosting: NSHostingView<MacOverlayView>?

    func show(_ content: MacOverlayContent) {
        let panel = panel ?? makePanel()
        shown.content = content
        guard let hosting else { return }
        // The card is sized to what it says, so it is measured after the
        // content lands and before the panel is placed.
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        // Ordered front without activating: a menu bar app that activated here
        // would pull focus off the window being typed into.
        panel.orderFrontRegardless()
        fade(panel, to: 1)
    }

    func hide() {
        guard let panel, panel.alphaValue > 0 else { return }
        fade(panel, to: 0)
    }

    private func makePanel() -> NSPanel {
        let panel = NonFocusingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // Follows the user across spaces and draws over a full-screen app,
        // which is where most of the typing this is previewing happens.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let hosting = NSHostingView(rootView: MacOverlayView(shown: shown))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    /// The screen the pointer is on, not `NSScreen.main`: for a menu bar app
    /// that is the screen with the key window, which is rarely the one being
    /// worked on. A fifth of the way up keeps the card clear of what is being
    /// clicked, and it is placed again on every show because the pointer may
    /// have moved to another display since the last one.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.minY + visible.height / 5).rounded()
        ))
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOutIfFadedAway() }
        })
    }

    /// A show that arrives during a fade out wins: the panel is only taken off
    /// screen if it is still invisible when the fade lands.
    private func orderOutIfFadedAway() {
        guard let panel, panel.alphaValue == 0 else { return }
        panel.orderOut(nil)
    }
}

/// Refusing both is what keeps injected keys going to the app in front.
private final class NonFocusingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Carries the current content into SwiftUI. The presenter only publishes a
/// change when there is one, so this rebuilds the card no more often than the
/// lit cell actually moves.
@MainActor
final class MacOverlayContentBox: ObservableObject {
    @Published var content: MacOverlayContent = .nothing
}
#endif
