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

    /// For a sheet on its way in or out.  UIKit pins the orientation to the
    /// current one while a presentation runs, so a turn asked for now is
    /// undone and then redone once the sheet lands: two extra rotations.  Left
    /// alone, UIKit re-reads the delegate as the transition ends and turns
    /// once, so all this does is make sure it reads the new mask.
    static func applyAfterPresentation(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
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
