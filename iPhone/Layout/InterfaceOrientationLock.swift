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

    /// Changing the mask also asks the window to rotate now rather than at the
    /// next natural rotation.
    static func apply(_ mask: UIInterfaceOrientationMask) {
        guard mask != self.mask else { return }
        self.mask = mask

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            // The controllers re-read the delegate first; asked the other way
            // round, the geometry request is refused against the old mask.
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                IPhoneDebugLog.emit("orientationUpdateFailed", ["reason": error.localizedDescription])
            }
        }
    }
}

final class PhoneRemoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        InterfaceOrientationLock.mask
    }
}
#endif
