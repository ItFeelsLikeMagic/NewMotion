import Foundation

#if os(macOS)
import Carbon.HIToolbox
#endif

public protocol SafeTranscriptInsertionSink: AnyObject {
    /// Implementations must route this through the existing SAFE-001/SAFE-002
    /// text policy.  This protocol does not expose CGEvent or raw key codes.
    @discardableResult
    func insertTranscript(_ text: String) -> Bool

    /// Removes `count` characters back from the caret through that same path,
    /// so a normalizer that reworded settled text can correct it in place.
    @discardableResult
    func deleteBackward(_ count: Int) -> Bool
}

/// Keeps Speech insertion on the existing SAFE-001/SAFE-002 policy path.
extension SafeInputInjector: SafeTranscriptInsertionSink {
    @discardableResult
    public func insertTranscript(_ text: String) -> Bool {
        submit(.text(text)) == .applied
    }

    @discardableResult
    public func deleteBackward(_ count: Int) -> Bool {
        for _ in 0..<count {
            guard submit(.hotkey(.deleteBackward)) == .applied else { return false }
        }
        return true
    }
}

public enum SecureInput {
    /// True while a password field or other secure input session is active;
    /// spoken text is never typed into one.
    @Sendable public static func isActive() -> Bool {
        #if os(macOS)
        IsSecureEventInputEnabled()
        #else
        false
        #endif
    }
}
