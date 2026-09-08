import Foundation
@testable import NewMotionShared

/// A link the tests can put in any state and watch being started, stopped,
/// and aimed.  It carries nothing; a test that wants the phone to hear
/// something calls `onMessage` itself.
final class FakeMessageLink: MessageLink {
    // Searching, not connected: the handshake hello and its retry timer stay
    // out of the way of a test that is watching something else.
    var state: RemoteLinkState = .searching
    var peerName: String?
    var maximumMessageBytes = 512
    var onStateChange: ((RemoteLinkState) -> Void)?
    var onMessage: ((LinkChannel, Data) -> Void)?
    var onReadyToSend: (() -> Void)?
    var onError: ((LinkError) -> Void)?
    private(set) var beacons: [UUID] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [(channel: LinkChannel, message: Data)] = []

    /// The handshake is the one traffic a test reads back; everything on the
    /// data channel is sealed, so tests count those rather than open them.
    var controlMessages: [Data] { sent.filter { $0.channel == .control }.map(\.message) }
    var dataMessageCount: Int { sent.count { $0.channel == .data } }

    func send(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult {
        sent.append((channel, message))
        return .sent
    }
    func setBeacons(_ beacons: [UUID]) { self.beacons = beacons }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}
