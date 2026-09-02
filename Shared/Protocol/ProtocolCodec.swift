import Foundation

/// Bounds applied before and during decoding of untrusted wire bytes.
public enum ProtocolLimits {
    /// Leaves room for BLE framing/transport metadata while allowing the
    /// largest bounded audio/text payloads.
    public static let maximumEnvelopeBytes = 8_192
}

/// Canonical v1 JSON codec. BLE framing and encryption are deliberately
/// separate concerns; this codec only owns envelope serialization and checks.
public enum ProtocolCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode(_ envelope: ProtocolEnvelope) throws -> [UInt8] {
        try envelope.validate()
        do {
            let bytes = Array(try encoder.encode(envelope))
            guard bytes.count <= ProtocolLimits.maximumEnvelopeBytes else {
                throw ProtocolError.envelopeTooLarge(
                    actual: bytes.count,
                    limit: ProtocolLimits.maximumEnvelopeBytes
                )
            }
            return bytes
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw ProtocolError.malformedInput
        }
    }

    public static func decode(_ bytes: [UInt8]) throws -> ProtocolEnvelope {
        guard !bytes.isEmpty else { throw ProtocolError.emptyInput }
        guard bytes.count <= ProtocolLimits.maximumEnvelopeBytes else {
            throw ProtocolError.envelopeTooLarge(
                actual: bytes.count,
                limit: ProtocolLimits.maximumEnvelopeBytes
            )
        }

        do {
            let envelope = try decoder.decode(ProtocolEnvelope.self, from: Data(bytes))
            try envelope.validate()
            return envelope
        } catch let error as ProtocolError {
            throw error
        } catch {
            // Do not surface decoder descriptions; they may include input
            // fragments. Tests classify all malformed/truncated JSON here.
            throw ProtocolError.malformedInput
        }
    }
}
