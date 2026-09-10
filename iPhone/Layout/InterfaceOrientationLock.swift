#if canImport(UIKit) && os(iOS)
import UIKit

/// Which way the screen may face, decided by the layout mode rather than by
/// how the phone happens to be held.
@MainActor
enum InterfaceOrientationLock {
    /// The delegate is asked before any SwiftUI view exists, so the starting
    /// mask comes straight from the persisted layout mode.
    static private(set) var mask: UIInterfaceOrientationMask = {
        let stored = UserDefaults.standard.string(forKey: "remoteLayoutMode") ?? ""
        return (RemoteLayoutMode(rawValue: stored) ?? .vertical).orientations
    }()

    private static var pendingTransition: (@MainActor () -> Void)?

    /// A layout change has nothing else in motion, so the root controller
    /// re-reads the delegate and UIKit turns the screen at once.
    static func apply(_ mask: UIInterfaceOrientationMask) {
        guard mask != self.mask else { return }
        self.mask = mask

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }

    /// Turns the screen and presents or dismisses a sheet in the same motion.
    /// UIKit pins a presentation to whichever way the screen faces as it
    /// begins, so a sheet started in the same pass as the turn is pinned the
    /// old way up, and the turn is undone and redone once the sheet lands.
    /// The system applies the turn a moment after it is asked for, and
    /// `screenTurned` is what says so; a sheet started there is pinned the
    /// new way up and slides while the screen is still turning.  A screen
    /// already facing an allowed way has nothing to wait for.
    static func turn(
        to mask: UIInterfaceOrientationMask,
        then transition: @escaping @MainActor () -> Void
    ) {
        apply(mask)
        let scene = UIApplication.shared.connectedScenes.lazy
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let scene,
              !mask.contains(scene.effectiveGeometry.interfaceOrientation.mask)
        else {
            transition()
            return
        }
        pendingTransition = transition
    }

    /// The screen has begun to turn.  Whatever `turn` was holding back goes
    /// now, so its animation runs alongside the rest of the rotation.
    static func screenTurned() {
        let transition = pendingTransition
        pendingTransition = nil
        transition?()
    }

    /// For a sheet already on its way out with nothing to hand it the turn
    /// first, such as a swipe down.  UIKit re-reads the delegate as the
    /// transition ends and turns once, so all this does is make sure it
    /// reads the new mask.
    static func applyAfterPresentation(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
    }
}

private extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask {
        UIInterfaceOrientationMask(rawValue: 1 << UInt(rawValue))
    }
}

final class NewMotionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        InterfaceOrientationLock.mask
    }
}
#endif
