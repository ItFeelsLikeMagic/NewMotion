import Foundation

#if os(macOS)
import Carbon.HIToolbox
#endif

public protocol SafeTranscriptInsertionSink: AnyObject {
    /// Implementations must route this through the existing SAFE-001/SAFE-002
    /// text policy.  This protocol does not expose CGEvent or raw key codes.
    @discardableResult
    func insertTranscript(_ text: String) -> Bool
}

/// Keeps Speech insertion on the existing SAFE-001/SAFE-002 policy path.
extension SafeInputInjector: SafeTranscriptInsertionSink {
    @discardableResult
    public func insertTranscript(_ text: String) -> Bool {
        submit(.text(text)) == .applied
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
