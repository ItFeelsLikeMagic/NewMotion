import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// The Bluetooth answer to `InputLink`.  It owns every wire concern for input:
/// the authenticated session, the envelope sequence, message numbering,
/// fragmenting to the notification size, and which channel carries what.
@MainActor
final class BLEInputLink: InputLink {
    /// Message IDs only have to be unique among the messages being reassembled
    /// at once, so each sender takes a range.  Voice owns the top quarter and
    /// the handshake counts up from one; input sits between them.
    private static let firstMessageID: UInt32 = 1 << 30
    private static let lastMessageID: UInt32 = (1 << 31) - 1

    private let peripheral: IPhoneBLEPeripheralTransport
    private var session: PairingSession?
    private var nextEnvelopeSequence: UInt64 = 1
    private var nextMessageID: UInt32 = BLEInputLink.firstMessageID

    var onReadyToSend: (() -> Void)?

    init(peripheral: IPhoneBLEPeripheralTransport) {
        self.peripheral = peripheral
        peripheral.onReadyToSend = { [weak self] in
            MainActor.assumeIsolated { self?.onReadyToSend?() }
        }
    }

    /// A new session restarts both counters, matching the Mac, which starts a
    /// fresh receive window with it.
    func setSession(_ session: PairingSession?) {
        self.session = session
        nextEnvelopeSequence = 1
        nextMessageID = Self.firstMessageID
    }

    var isReady: Bool { session != nil && peripheral.state == .ready }

    func send(_ message: InputMessage, delivery: InputDelivery) -> InputSendResult {
        guard let session, peripheral.state == .ready else { return .unavailable }
        do {
            let frames = try frames(for: message, session: session)
            // A message too big for one notification has to go whole or not at
            // all, so it queues even when the caller would rather keep it.
            let mustQueue = delivery == .ordered || frames.count > 1
            for (index, frame) in frames.enumerated() {
                let enqueue = mustQueue || index > 0
                switch peripheral.send(frame, on: .data, enqueue: enqueue) {
                case .sent, .queued:
                    continue
                case .queueFull where !enqueue:
                    return .busy
                case .queueFull, .notReady, .unsupportedChannel:
                    return .unavailable
                }
            }
            return .sent
        } catch {
            return .unavailable
        }
    }

    private func frames(for message: InputMessage, session: PairingSession) throws -> [Data] {
        let messageID = takeMessageID()
        switch message {
        case let .compact(body, type):
            return try session.wrapBinary(
                body,
                messageType: type.rawValue,
                messageID: messageID,
                maximumValueLength: peripheral.maximumUpdateValueLength,
                reliable: false
            )
        case let .payload(payload):
            let envelope = ProtocolEnvelope(
                sessionID: try SessionID(bytes: Array(session.sessionID)),
                sequence: takeEnvelopeSequence(),
                timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                payload: payload
            )
            return try session.wrapApplication(
                envelope,
                messageID: messageID,
                maximumValueLength: peripheral.maximumUpdateValueLength
            )
        }
    }

    private func takeMessageID() -> UInt32 {
        let id = nextMessageID
        nextMessageID = id >= Self.lastMessageID ? Self.firstMessageID : id &+ 1
        return id
    }

    private func takeEnvelopeSequence() -> UInt64 {
        let sequence = nextEnvelopeSequence
        nextEnvelopeSequence = sequence == UInt64.max ? 1 : sequence &+ 1
        return sequence
    }
}
