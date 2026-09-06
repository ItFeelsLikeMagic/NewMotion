import Foundation

#if os(macOS)
import Carbon.HIToolbox
#endif

public enum SecureInput {
    /// True while a password field or other secure input session is active.
    /// Nothing the phone sends is typed into one, and the boost walk does not
    /// read the window either.
    @Sendable public static func isActive() -> Bool {
        #if os(macOS)
        IsSecureEventInputEnabled()
        #else
        false
        #endif
    }
}
