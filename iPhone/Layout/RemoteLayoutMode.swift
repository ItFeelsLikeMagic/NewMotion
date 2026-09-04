#if canImport(UIKit) && os(iOS)
import UIKit

/// How the phone is held, and so how the remote arranges itself.  Each mode
/// owns the orientation it needs, so switching mode turns the screen.
enum RemoteLayoutMode: String, CaseIterable, Sendable {
    /// Phone upright: trackpad above the keypad.
    case vertical
    /// Phone sideways: keys under one thumb, trackpad under the other.
    case controller

    var orientations: UIInterfaceOrientationMask {
        switch self {
        case .vertical: return .portrait
        case .controller: return .landscape
        }
    }

    /// The drag targets follow the hold bar: both sides when it sits between
    /// the thumbs, one side when it sits under one of them.
    func pushToTalkZoneSides(mirrored: Bool) -> PushToTalkZoneSides {
        switch self {
        case .vertical: return .both
        case .controller: return mirrored ? .trailing : .leading
        }
    }

    var next: RemoteLayoutMode {
        switch self {
        case .vertical: return .controller
        case .controller: return .vertical
        }
    }

    /// The toggle pictures the mode the tap switches to, not the one on
    /// screen, so the button says where it goes.
    var toggleSymbol: String {
        switch self {
        case .vertical: return "iphone.landscape"
        case .controller: return "iphone"
        }
    }

    var toggleLabel: String {
        switch self {
        case .vertical: return "Switch to controller mode"
        case .controller: return "Switch to vertical mode"
        }
    }
}
#endif
