import CryptoKit
import Foundation

/// The service UUID a phone advertises so that only the Mac it means to reach
/// looks twice.  One pairing has one beacon for its whole life: the QR code's
/// pairing ID is the ID both sides file the trust record under, so the same
/// value carries a phone through its first handshake and every reconnect
/// after.  The GATT service itself keeps `NewMotionGATT.serviceUUID`; the
/// beacon is only what the air carries.
///
/// Hashing rather than advertising the ID itself keeps the value in its own
/// namespace; it adds no secrecy, since anyone who saw the QR code knows the
/// ID.  A rotating beacon would need a shared key and is a later step.
public enum NewMotionBeacon {
    private static let domain = Data("newmotion-beacon-v1".utf8)

    public static func uuid(pairingID: UUID) -> UUID {
        var input = domain
        input.append(contentsOf: withUnsafeBytes(of: pairingID.uuid) { Data($0) })
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        // Version 4 and RFC 4122 variant bits, so the value reads as an
        // ordinary random UUID everywhere it is shown.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
