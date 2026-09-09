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
    private let shown = MacOverlayContentBox()
    private var panel: NSPanel?
    /// What the card is meant to be doing, which `alphaValue` cannot say: a tap
    /// short enough to begin and commit inside the 120 ms fade would otherwise
    /// hide a card that is still on its way in, and leave it up for good.
    private var isShowing = false

    func show(_ content: MacOverlayContent) {
        let panel = panel ?? makePanel()
        // Already up: the card redraws itself and nothing else happens. Placing
        // and fading a panel per dictation partial would be a screen scan and
        // an animation ten times a second for a card that has not moved.
        guard !isShowing else {
            shown.content = content
            return
        }
        // A card arriving on a panel that is down, or on its way down, is put
        // in place without the card's own cross-fade: the panel fading in is
        // the only animation, or the keys of the last card ghost under the
        // words of this one.
        Self.withoutAnimation { shown.content = content }
        isShowing = true
        position(panel)
        // Ordered front without activating: a menu bar app that activated here
        // would pull focus off the window being typed into.
        panel.orderFrontRegardless()
        fade(panel, to: 1)
    }

    func hide() {
        guard let panel, isShowing else { return }
        isShowing = false
        fade(panel, to: 0)
    }

    private func makePanel() -> NSPanel {
        let panel = NonFocusingPanel(
            contentRect: NSRect(origin: .zero, size: MacOverlayStyle.panelSize),
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
        panel.contentView = NSHostingView(rootView: MacOverlayView(shown: shown))
        self.panel = panel
        return panel
    }

    /// The screen the pointer is on, not `NSScreen.main`: for a menu bar app
    /// that is the screen with the key window, which is rarely the one being
    /// worked on. The card sits a fifth of the way up, clear of what is being
    /// clicked, and is placed again on every show because the pointer may have
    /// moved to another display since the last one.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // The panel is one fixed size and the card is centred in it, so it is
        // the middle of the panel that is aimed a fifth of the way up. Pinned
        // inside the visible frame afterwards: the panel is taller than a fifth
        // of a short display, and aiming alone would hang it off the bottom.
        let x = visible.midX - size.width / 2
        let y = visible.minY + visible.height / 5 - size.height / 2
        panel.setFrameOrigin(NSPoint(
            x: Self.pinned(x, low: visible.minX, high: visible.maxX - size.width),
            y: Self.pinned(y, low: visible.minY, high: visible.maxY - size.height)
        ))
    }

    /// A panel wider or taller than the screen has no room to be pinned into,
    /// so it starts at the visible frame's edge and overhangs the far one.
    private static func pinned(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        max(low, min(value, max(low, high))).rounded()
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MacOverlayStyle.fadeDuration
            panel.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOutIfFadedAway() }
        })
    }

    /// A show that arrives during a fade out wins: the panel is only taken off
    /// screen if it is still meant to be gone when the fade lands.
    private func orderOutIfFadedAway() {
        guard let panel, !isShowing else { return }
        panel.orderOut(nil)
        Self.withoutAnimation { shown.content = .nothing }
    }

    private static func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
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
