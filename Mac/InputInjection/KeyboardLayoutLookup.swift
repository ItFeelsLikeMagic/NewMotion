import Carbon.HIToolbox
import Foundation

/// Where a character sits on the keyboard the user is actually typing on.
public protocol KeyboardLayoutLookup: AnyObject, Sendable {
    /// The key that types `character` with no modifier held, or nil when the
    /// layout cannot type it that way.
    func keyCode(for character: Character) -> UInt16?
}

/// Reads the active keyboard layout.  A chord has to be posted as the key that
/// produces its letter under that layout, not as the key QWERTY keeps the
/// letter on: on Colemak the QWERTY N position types "k", so Command+N posted
/// by position arrives as Command+K.
///
/// The map is rebuilt only when the input source changes, so switching layouts
/// mid-session is picked up without rereading the layout for every chord.
public final class ActiveKeyboardLayout: KeyboardLayoutLookup, @unchecked Sendable {
    public static let shared = ActiveKeyboardLayout()

    private let lock = NSLock()
    private var sourceID: String?
    private var codes: [Character: UInt16] = [:]

    public init() {}

    public func keyCode(for character: Character) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        let identifier = Self.identifier(of: source)
        lock.lock()
        defer { lock.unlock() }
        if identifier != sourceID {
            sourceID = identifier
            codes = Self.codes(of: source)
        }
        return codes[Character(character.lowercased())]
    }

    private static func identifier(of source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    /// Every key the layout can type unmodified, keyed by what it types.  A
    /// layout may put one character on two keys; the lower code is the one a
    /// shortcut is written against.
    private static func codes(of source: TISInputSource) -> [Character: UInt16] {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let data = Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        var result: [Character: UInt16] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return
            }
            for code in UInt16(0)...127 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    code,
                    UInt16(kUCKeyActionDown),
                    0,
                    keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]) else {
                    continue
                }
                let character = Character(scalar)
                if result[character] == nil { result[character] = code }
            }
        }
        return result
    }
}
