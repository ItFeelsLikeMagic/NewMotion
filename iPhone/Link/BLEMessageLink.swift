import Foundation

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// The Bluetooth answer to `MessageLink`.  Everything a whole message needs to
/// cross Core Bluetooth lives here: the notification size, fragmenting and
/// reassembly, message numbering, which characteristic a channel lands on, and
/// the beacon that has to be relit for the Mac to find this phone.  Nothing
/// above this line knows any of it.
///
/// Core Bluetooth calls back on the main queue and every caller sends from
/// there, so this class is single-threaded in practice; the `Sendable` claim
/// only lets the pulse timer hold it.
final class BLEMessageLink: MessageLink, @unchecked Sendable {
    /// How often the beacon is relit so a Mac that began scanning late still
    /// sees us.  `pulseAdvertising` does nothing unless the beacon is really
    /// down, so this never interrupts a connection in progress.
    private static let advertisingPulseInterval: TimeInterval = 3

    private let peripheral: IPhoneBLEPeripheralTransport
    private let fragmenter = BLEFragmenter()
    private var reassemblers: [LinkChannel: BLEReassembler] = [:]
    private let messageIDLock = NSLock()
    private var nextMessageID: UInt32 = 1
    private var reportedState: RemoteLinkState
    private var pulseTimer: Timer?

    var onStateChange: ((RemoteLinkState) -> Void)?
    var onMessage: ((LinkChannel, Data) -> Void)?
    var onReadyToSend: (() -> Void)?
    var onError: ((LinkError) -> Void)?

    init(peripheral: IPhoneBLEPeripheralTransport) {
        self.peripheral = peripheral
        reportedState = Self.linkState(for: peripheral.state)
        // An arriving fragment is bounded by the Mac's notification size, not
        // by this phone's, so reassembly accepts anything the envelope limit
        // allows.
        let inboundLimit = BLEFramingLimits.maximumEnvelopeBytes + BLEFramingLimits.headerBytes
        for channel in LinkChannel.allCases {
            reassemblers[channel] = try? BLEReassembler(maximumValueLength: inboundLimit)
        }
        peripheral.onStateChange = { [weak self] state in self?.handle(state) }
        peripheral.onFrameReceived = { [weak self] channel, frame in self?.handle(channel: channel, frame: frame) }
        peripheral.onReadyToSend = { [weak self] in self?.onReadyToSend?() }
        peripheral.onTransportError = { [weak self] error in
            self?.onError?(.setupFailed(error.localizedDescription))
        }
    }

    var state: RemoteLinkState { Self.linkState(for: peripheral.state) }

    /// A peripheral is told nothing about the central that subscribes to it.
    var peerName: String? { nil }

    var maximumMessageBytes: Int {
        let perFragment = peripheral.maximumUpdateValueLength - BLEFramingLimits.headerBytes
        return min(BLEFramingLimits.maximumEnvelopeBytes, perFragment * BLEFramingLimits.maximumFragments)
    }

    func start() {
        peripheral.setForeground(true)
        guard pulseTimer == nil else { return }
        let timer = Timer(timeInterval: Self.advertisingPulseInterval, repeats: true) { [weak self] _ in
            self?.peripheral.pulseAdvertising()
        }
        // Common mode, so a finger tracking on the trackpad does not hold the
        // beacon down.
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    func stop() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        peripheral.setForeground(false)
    }

    /// Timed from the outside so every way out is counted once: the split
    /// exists only so a refusal cannot slip past an early return.
    @discardableResult
    func send(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult {
        let clock = LatencyClock()
        let result = deliver(message, on: channel, delivery: delivery)
        PhoneLatency.linkSend(on: channel).record(clock, sent: result == .sent)
        return result
    }

    private func deliver(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult {
        guard message.count <= maximumMessageBytes else { return .tooLarge }
        guard state == .connected else { return .notConnected }
        guard let fragments = try? fragmenter.fragment(
            payload: message,
            kind: Self.frameKind(for: channel),
            reliable: delivery.isReliable,
            messageID: takeMessageID(),
            maximumValueLength: peripheral.maximumUpdateValueLength
        ) else { return .tooLarge }
        // A `latestWins` message takes the wire or the caller's answer, never a
        // queue: a stored cursor delta replays a path the hand has already
        // left.  Everything else queues, and only if the whole of it fits,
        // because half a message is one the Mac can never put back together.
        let queued = delivery.mayQueue
        if queued, fragments.count > peripheral.queueCapacity(on: channel) { return .busy }
        for fragment in fragments {
            switch peripheral.send(fragment, on: channel, enqueue: queued) {
            case .sent, .queued:
                continue
            case .queueFull:
                return .busy
            case .notReady, .unsupportedChannel:
                return .notConnected
            }
        }
        return .sent
    }

    private func handle(_ peripheralState: BLEPeripheralLifecycleState) {
        let next = Self.linkState(for: peripheralState)
        guard next != reportedState else { return }
        reportedState = next
        // A link that went away takes its half-built messages with it; the Mac
        // starts numbering afresh on the next one.
        if next != .connected {
            for reassembler in reassemblers.values { reassembler.reset() }
        }
        onStateChange?(next)
    }

    private func handle(channel: LinkChannel, frame: Data) {
        guard let reassembler = reassemblers[channel] else { return }
        do {
            switch try reassembler.append(frame) {
            case .incomplete, .duplicate:
                return
            case let .complete(payload, kind, _, _):
                guard kind == Self.frameKind(for: channel) else { throw BLEFramingError.unknownFrameKind }
                onMessage?(channel, payload)
            }
        } catch {
            onError?(.malformedMessage)
        }
    }

    /// One counter for every channel and every sender.  IDs only have to be
    /// unique among the messages being reassembled at the same time, and the
    /// Mac groups fragments by whichever ID arrives.
    private func takeMessageID() -> UInt32 {
        messageIDLock.lock()
        defer { messageIDLock.unlock() }
        let id = nextMessageID
        // Zero is not a legal message ID on the wire.
        nextMessageID = id == UInt32.max ? 1 : id + 1
        return id
    }

    private static func frameKind(for channel: LinkChannel) -> BLEFrameKind {
        switch channel {
        case .control: return .control
        case .data: return .data
        }
    }

    /// The link stops at `connected`: one notify channel is a half-built link,
    /// both are a usable one, and whether the Mac is trusted is the app's
    /// question.
    private static func linkState(for state: BLEPeripheralLifecycleState) -> RemoteLinkState {
        switch state {
        case .idle, .stopped, .waitingForBluetooth: return .unavailable
        case .publishing, .advertising: return .searching
        case .connected: return .connecting
        case .ready: return .connected
        }
    }
}
