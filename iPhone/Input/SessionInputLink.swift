import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The sealed answer to `InputLink`.  It owns the two things that sit above a
/// link and below the pipeline: the authenticated session and the envelope
/// sequence.  Message numbering, packet size, and fragmenting belong to the
/// link, so this class names no transport.
@MainActor
final class SessionInputLink: InputLink {
    private let link: MessageLink
    private var session: PairingSession?
    private var nextEnvelopeSequence: UInt64 = 1

    var onReadyToSend: (() -> Void)?

    init(link: MessageLink) {
        self.link = link
        link.onReadyToSend = { [weak self] in
            MainActor.assumeIsolated { self?.onReadyToSend?() }
        }
    }

    /// A new session restarts the sequence, matching the Mac, which starts a
    /// fresh receive window with it.
    func setSession(_ session: PairingSession?) {
        self.session = session
        nextEnvelopeSequence = 1
    }

    var isReady: Bool { session != nil && link.state == .connected }

    func send(_ message: InputMessage, delivery: InputDelivery) -> InputSendResult {
        guard let session, link.state == .connected else { return .unavailable }
        guard let sealed = try? seal(message, with: session) else { return .unavailable }
        switch link.send(sealed, on: .data, delivery: delivery == .ordered ? .reliable : .latestWins) {
        case .sent:
            return .sent
        case .busy:
            return .busy
        case .notConnected, .tooLarge:
            return .unavailable
        }
    }

    private func seal(_ message: InputMessage, with session: PairingSession) throws -> Data {
        switch message {
        case let .compact(body, type):
            return try session.encrypt(plaintext: body, messageType: type.rawValue)
        case let .payload(payload):
            let envelope = ProtocolEnvelope(
                sessionID: try SessionID(bytes: Array(session.sessionID)),
                sequence: takeEnvelopeSequence(),
                timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                payload: payload
            )
            return try session.seal(envelope)
        }
    }

    private func takeEnvelopeSequence() -> UInt64 {
        let sequence = nextEnvelopeSequence
        nextEnvelopeSequence = sequence == UInt64.max ? 1 : sequence &+ 1
        return sequence
    }
}
