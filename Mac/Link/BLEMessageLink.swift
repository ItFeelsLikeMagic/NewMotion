import Foundation
#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// Bluetooth's answer to `MessageLink`. Scanning, the GATT dance, the packet
/// size, cutting a message up and putting it back together, and the clock that
/// gives up on a peer all live here. Above this line there are only whole
/// messages and four states.
///
/// The scan asks the radio only for the beacons it has been given, so a phone
/// addressed to another Mac is never seen, let alone connected to, and a phone
/// the system already holds a link to is taken up only once it has been seen on
/// one of those beacons. The GATT service itself stays
/// `NewMotionGATT.serviceUUID` on every phone.
///
/// Core Bluetooth delivers every callback on the main queue and the link's own
/// timer runs there too, so the connection state below is single-threaded.
public final class BLEMessageLink: MessageLink, @unchecked Sendable {
    /// How often the link looks at its own deadline and at the peripherals the
    /// system already holds a link to.
    private static let pollInterval: TimeInterval = 1
    /// Whole-message reassembly, so a frame is only rejected for being longer
    /// than any message may be.
    private static let reassemblyValueLength =
        BLEFramingLimits.maximumEnvelopeBytes + BLEFramingLimits.headerBytes

    public let maximumMessageBytes = BLEFramingLimits.maximumEnvelopeBytes

    public var onStateChange: ((RemoteLinkState) -> Void)?
    public var onMessage: ((LinkChannel, Data) -> Void)?
    public var onReadyToSend: (() -> Void)?
    public var onError: ((LinkError) -> Void)?

    public var state: RemoteLinkState { Self.linkState(for: lifecycle) }

    public var peerName: String? {
        let name = (connectedPeripheral ?? pendingPeripheral)?.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private let serviceUUID = NewMotionGATT.serviceUUID
    private let adapter: MacCentralManagerAdapter
    private let connectionTimeout: TimeInterval
    private let writeQueueLimit: Int
    private let now: () -> Date
    private let latency: LatencyTracker?
    private let fragmenter = BLEFragmenter()
    private let inbound: [LinkChannel: BLEReassembler]

    private var beacons: [UUID] = []
    /// Peripherals turned away by `rejectCurrentPeer`, so the poll that
    /// adopts a system-held connection does not pick the same one straight
    /// back up.
    private var shunned: Set<UUID> = []
    private var lifecycle: BLECentralLifecycleState = .idle
    private var connectedPeripheral: BLEDiscoveredPeripheral?
    private var pendingPeripheral: BLEDiscoveredPeripheral?
    private var pendingDeadline: Date?
    private var pendingSubscriptions: Set<UUID> = []
    private var subscribed: Set<UUID> = []
    private var maximumValueLength = BLEFramingLimits.minimumValueLength
    private var writeQueue: [(Data, UUID, BLEWriteType)] = []
    private var reliableWriteInFlight = false
    private var senderIsWaiting = false
    private var pollTimer: Timer?
    /// One counter across both channels: the far side keys partial messages by
    /// ID alone, so two channels must never hand out the same one.
    private let messageIDLock = NSLock()
    private var nextMessageID: UInt32 = 1

    public init(
        adapter: MacCentralManagerAdapter,
        connectionTimeout: TimeInterval = 10,
        writeQueueLimit: Int = BLEFramingLimits.maximumQueuedFrames,
        now: @escaping () -> Date = Date.init,
        latency: LatencyTracker? = nil
    ) {
        self.adapter = adapter
        self.connectionTimeout = max(1, connectionTimeout)
        self.writeQueueLimit = max(1, writeQueueLimit)
        self.now = now
        self.latency = latency
        self.inbound = Dictionary(
            uniqueKeysWithValues: LinkChannel.allCases.map { ($0, Self.makeReassembler()) }
        )
        adapter.onStateChange = { [weak self] state in self?.handleAdapterState(state) }
        adapter.onDiscoverPeripheral = { [weak self] peripheral in self?.handleDiscover(peripheral) }
        adapter.onConnected = { [weak self] peripheralID in self?.handleConnected(peripheralID) }
        adapter.onConnectionFailed = { [weak self] peripheralID, _ in self?.handleConnectionFailure(peripheralID) }
        adapter.onDisconnected = { [weak self] peripheralID, _ in self?.handleDisconnected(peripheralID) }
        adapter.onServicesDiscovered = { [weak self] peripheralID, services, error in self?.handleServices(peripheralID, services: services, error: error) }
        adapter.onServicesInvalidated = { [weak self] peripheralID, services in self?.handleServicesInvalidated(peripheralID, services: services) }
        adapter.onCharacteristicsDiscovered = { [weak self] peripheralID, serviceUUID, characteristics, error in self?.handleCharacteristics(peripheralID, serviceUUID: serviceUUID, characteristics: characteristics, error: error) }
        adapter.onNotificationState = { [weak self] peripheralID, characteristicUUID, enabled, error in self?.handleNotification(peripheralID, characteristicUUID: characteristicUUID, enabled: enabled, error: error) }
        adapter.onValue = { [weak self] peripheralID, characteristicUUID, data, error in self?.handleValue(peripheralID, characteristicUUID: characteristicUUID, data: data, error: error) }
        adapter.onReadyToWriteWithoutResponse = { [weak self] in self?.flushWrites() }
        adapter.onWriteComplete = { [weak self] error in self?.handleWriteComplete(error) }
        handleAdapterState(adapter.state)
    }

    deinit { pollTimer?.invalidate() }

    public func setBeacons(_ beacons: [UUID]) {
        guard beacons != self.beacons else { return }
        self.beacons = beacons
        // A phone stays turned away only until the set of peers changes, which
        // is what pairing that same phone again looks like from here.
        shunned.removeAll()
        guard adapter.state == .poweredOn else { return }
        switch lifecycle {
        case .scanning:
            adapter.stopScan()
            scanForBeacons()
        // A QR issued with nothing on the air has nobody looking for it until
        // something else calls `start()`, and the phone gives up first. An
        // empty list is the opposite case: nobody to look for, so saying we
        // are searching would be a lie.
        case .disconnected, .waitingForBluetooth:
            if !beacons.isEmpty { start() }
        // A link on its way up is already the one the user picked, an idle one
        // was never started, and a stopped one was stopped on purpose.
        case .idle, .connecting, .discovering, .subscribing, .ready, .stopped:
            break
        }
    }

    public func start() {
        guard adapter.state == .poweredOn else {
            transition(to: .waitingForBluetooth)
            return
        }
        clearConnection()
        transition(to: .scanning)
        scanForBeacons()
        adoptSystemConnectedPeripheral()
        startPolling()
    }

    /// With no beacons there is nobody to look for, but a phone the system
    /// already holds a link to is still adopted by polling.
    private func scanForBeacons() {
        guard !beacons.isEmpty else { return }
        adapter.scan(for: beacons)
    }

    public func stop() {
        stopPolling()
        adapter.stopScan()
        if let peripheral = connectedPeripheral ?? pendingPeripheral {
            adapter.cancelConnection(peripheralID: peripheral.identifier)
        }
        clearConnection()
        transition(to: .stopped)
    }

    /// Drops the peer on the link now and keeps it off until the beacons
    /// change. Beacons decide which phones a scan answers, but a phone macOS is
    /// already holding a connection to is adopted without one, so a phone this
    /// Mac has forgotten can only be refused after it has named itself.
    public func rejectCurrentPeer() {
        guard let peripheral = connectedPeripheral ?? pendingPeripheral else { return }
        shunned.insert(peripheral.identifier)
        adapter.stopScan()
        adapter.cancelConnection(peripheralID: peripheral.identifier)
        clearConnection()
        if adapter.state == .poweredOn {
            start()
        } else {
            transition(to: .disconnected)
        }
    }

    @discardableResult
    public func send(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult {
        let clock = LatencyClock()
        let result = write(message, on: channel, delivery: delivery)
        switch result {
        case .sent:
            latency?.record(microseconds: clock.elapsedMicroseconds)
        // A full queue and a link that is not up are the refusals worth
        // watching: while the queue backs up these climb and the timings do not.
        case .busy, .notConnected:
            latency?.recordRefusal()
        // Retrying will not help, so it says nothing about how the link is
        // keeping up.
        case .tooLarge:
            break
        }
        return result
    }

    private func write(_ message: Data, on channel: LinkChannel, delivery: LinkDelivery) -> LinkSendResult {
        guard !message.isEmpty, message.count <= maximumMessageBytes else { return .tooLarge }
        // A write is allowed one callback before `.connected`: the phone's
        // hello can arrive in the same turn as the last subscribe, and the
        // answer to it must not be dropped.
        guard lifecycle == .ready || lifecycle == .subscribing,
              let peripheral = connectedPeripheral ?? pendingPeripheral else { return .notConnected }
        guard let frames = try? fragmenter.fragment(
            payload: message,
            kind: Self.frameKind(for: channel),
            reliable: delivery.isReliable,
            messageID: allocateMessageID(),
            maximumValueLength: maximumValueLength
        ) else { return .tooLarge }
        // A message goes out whole or not at all; half of one is a frame the
        // far side waits on forever.
        guard writeQueue.count + frames.count <= writeQueueLimit else {
            senderIsWaiting = true
            return .busy
        }
        let characteristic = Self.characteristic(for: channel)
        let type: BLEWriteType = delivery.isReliable ? .withResponse : .withoutResponse
        for frame in frames {
            writeQueue.append((frame, characteristic, type))
        }
        flushWrites(peripheral: peripheral)
        return .sent
    }

    /// The link's own timer beats once a second. It enforces the deadline for
    /// setting a connection up, and while scanning keeps polling for a phone
    /// the system already holds a link to.
    public func tick() {
        if let deadline = pendingDeadline, now() >= deadline {
            failLink(error: .peerNotFound)
            return
        }
        if lifecycle == .scanning { adoptSystemConnectedPeripheral() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.tick()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// macOS keeps the BLE link to a paired iPhone alive after the phone app
    /// quits, and a peripheral the system is connected to never shows up in a
    /// scan; it only appears here once the relaunched app republishes the
    /// service.
    ///
    /// The beacon cannot be read back from a link the system already holds, so
    /// adoption cannot check the address the way a scan does. It does not have
    /// to: a phone that is not ours gets no further than its hello, which
    /// `turnAwayUnknownPhone` refuses and shuns. Requiring an address here
    /// instead would strand the case this exists for, because a phone that
    /// still believes in a dead subscriber never advertises again.
    private func adoptSystemConnectedPeripheral() {
        for peripheral in adapter.connectedPeripherals(for: serviceUUID) {
            handleDiscover(peripheral)
            if lifecycle != .scanning { break }
        }
    }

    private func handleAdapterState(_ managerState: BLEPeripheralManagerState) {
        switch managerState {
        case .poweredOn:
            if lifecycle == .waitingForBluetooth { start() }
        case .unknown, .resetting, .unsupported, .unauthorized, .poweredOff:
            stopPolling()
            adapter.stopScan()
            if let peripheral = connectedPeripheral ?? pendingPeripheral {
                adapter.cancelConnection(peripheralID: peripheral.identifier)
            }
            let wasUp = state != .unavailable
            clearConnection()
            transition(to: .waitingForBluetooth)
            if wasUp { onError?(.unavailable) }
        }
    }

    private func handleDiscover(_ peripheral: BLEDiscoveredPeripheral) {
        guard lifecycle == .scanning, !shunned.contains(peripheral.identifier) else { return }
        adapter.stopScan()
        pendingPeripheral = peripheral
        pendingDeadline = now().addingTimeInterval(connectionTimeout)
        transition(to: .connecting)
        adapter.connect(peripheralID: peripheral.identifier)
    }

    private func handleConnected(_ peripheralID: UUID) {
        guard pendingPeripheral?.identifier == peripheralID else { return }
        pendingDeadline = now().addingTimeInterval(connectionTimeout)
        transition(to: .discovering)
        adapter.discoverServices(peripheralID: peripheralID, serviceUUID: serviceUUID)
    }

    private func handleConnectionFailure(_ peripheralID: UUID) {
        guard pendingPeripheral?.identifier == peripheralID else { return }
        failLink(error: .peerNotFound)
    }

    private func handleDisconnected(_ peripheralID: UUID) {
        guard connectedPeripheral?.identifier == peripheralID || pendingPeripheral?.identifier == peripheralID else { return }
        failLink(error: .peerDisconnected)
    }

    private func handleServices(_ peripheralID: UUID, services: Set<UUID>, error: Error?) {
        guard lifecycle == .discovering, pendingPeripheral?.identifier == peripheralID else { return }
        guard error == nil, services.contains(serviceUUID) else {
            failLink(error: .setupFailed("the phone is not offering NewMotion"))
            return
        }
        transition(to: .subscribing)
        adapter.discoverCharacteristics(
            peripheralID: peripheralID,
            serviceUUID: serviceUUID,
            characteristicUUIDs: Array(NewMotionGATT.allCharacteristicUUIDs)
        )
    }

    /// The phone republished its GATT table, so every cached characteristic
    /// handle is dead. The link itself is still up, and a peripheral the system
    /// is connected to never shows up in a scan, so the only way back is to
    /// rediscover in place.
    private func handleServicesInvalidated(_ peripheralID: UUID, services: Set<UUID>) {
        guard let peripheral = connectedPeripheral ?? pendingPeripheral,
              peripheral.identifier == peripheralID,
              services.contains(serviceUUID) else { return }
        adapter.stopScan()
        connectedPeripheral = nil
        pendingPeripheral = peripheral
        pendingSubscriptions.removeAll()
        subscribed.removeAll()
        discardOutbound()
        resetInbound()
        pendingDeadline = now().addingTimeInterval(connectionTimeout)
        transition(to: .discovering)
        adapter.discoverServices(peripheralID: peripheralID, serviceUUID: serviceUUID)
    }

    private func handleCharacteristics(_ peripheralID: UUID, serviceUUID: UUID, characteristics: Set<UUID>, error: Error?) {
        guard lifecycle == .subscribing, pendingPeripheral?.identifier == peripheralID, serviceUUID == self.serviceUUID else { return }
        guard error == nil, characteristics.isSuperset(of: NewMotionGATT.allCharacteristicUUIDs) else {
            failLink(error: .setupFailed("the phone's NewMotion service is incomplete"))
            return
        }
        connectedPeripheral = pendingPeripheral
        pendingSubscriptions = [NewMotionGATT.phoneToMacDataUUID, NewMotionGATT.phoneToMacControlUUID]
        subscribed.removeAll()
        for characteristic in pendingSubscriptions {
            adapter.subscribe(peripheralID: peripheralID, characteristicUUID: characteristic)
        }
    }

    private func handleNotification(_ peripheralID: UUID, characteristicUUID: UUID, enabled: Bool, error: Error?) {
        guard lifecycle == .subscribing, pendingPeripheral?.identifier == peripheralID else { return }
        guard error == nil, enabled, pendingSubscriptions.contains(characteristicUUID) else {
            failLink(error: .setupFailed("could not listen to the phone"))
            return
        }
        subscribed.insert(characteristicUUID)
        guard subscribed == pendingSubscriptions else { return }
        connectedPeripheral = pendingPeripheral
        pendingPeripheral = nil
        pendingDeadline = nil
        maximumValueLength = max(
            BLEFramingLimits.minimumValueLength,
            adapter.maximumWriteValueLength(peripheralID: peripheralID, characteristicUUID: NewMotionGATT.macToPhoneDataUUID)
        )
        transition(to: .ready)
        flushWrites()
    }

    private func handleValue(_ peripheralID: UUID, characteristicUUID: UUID, data: Data?, error: Error?) {
        guard connectedPeripheral?.identifier == peripheralID else { return }
        guard error == nil else {
            onError?(.malformedMessage)
            return
        }
        guard let data, let channel = Self.channel(for: characteristicUUID),
              let reassembler = inbound[channel] else { return }
        do {
            switch try reassembler.append(data) {
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

    private func handleWriteComplete(_ error: Error?) {
        reliableWriteInFlight = false
        guard error == nil else {
            onError?(.peerDisconnected)
            return
        }
        flushWrites()
    }

    private func flushWrites(peripheral: BLEDiscoveredPeripheral? = nil) {
        guard let peripheral = peripheral ?? connectedPeripheral else { return }
        while let first = writeQueue.first {
            if first.2 == .withResponse, reliableWriteInFlight { return }
            if first.2 == .withResponse { reliableWriteInFlight = true }
            guard adapter.write(first.0, peripheralID: peripheral.identifier, characteristicUUID: first.1, type: first.2) else {
                if first.2 == .withResponse { reliableWriteInFlight = false }
                return
            }
            writeQueue.removeFirst()
            if first.2 == .withResponse { return }
        }
        if senderIsWaiting {
            senderIsWaiting = false
            onReadyToSend?()
        }
    }

    private func failLink(error: LinkError) {
        onError?(error)
        adapter.stopScan()
        if let peripheral = connectedPeripheral ?? pendingPeripheral {
            adapter.cancelConnection(peripheralID: peripheral.identifier)
        }
        clearConnection()
        // Always rescan so a trusted phone can reconnect without a new QR.
        if adapter.state == .poweredOn {
            start()
        } else {
            transition(to: .disconnected)
        }
    }

    private func clearConnection() {
        pendingPeripheral = nil
        pendingDeadline = nil
        connectedPeripheral = nil
        pendingSubscriptions.removeAll()
        subscribed.removeAll()
        discardOutbound()
        resetInbound()
    }

    private func discardOutbound() {
        writeQueue.removeAll(keepingCapacity: true)
        reliableWriteInFlight = false
        senderIsWaiting = false
    }

    private func resetInbound() {
        for reassembler in inbound.values { reassembler.reset() }
    }

    private func transition(to next: BLECentralLifecycleState) {
        guard lifecycle != next else { return }
        let previous = state
        lifecycle = next
        guard state != previous else { return }
        onStateChange?(state)
    }

    /// Zero is reserved by the frame header, so the counter wraps back to one.
    private func allocateMessageID() -> UInt32 {
        messageIDLock.lock()
        defer { messageIDLock.unlock() }
        let id = nextMessageID
        nextMessageID = id == UInt32.max ? 1 : id &+ 1
        return id
    }

    /// The reassembler only rejects a value length shorter than a header plus
    /// one byte, and this one is a whole message wide.
    private static func makeReassembler() -> BLEReassembler {
        try! BLEReassembler(maximumValueLength: reassemblyValueLength)
    }

    private static func linkState(for lifecycle: BLECentralLifecycleState) -> RemoteLinkState {
        switch lifecycle {
        case .idle, .waitingForBluetooth, .disconnected, .stopped: return .unavailable
        case .scanning: return .searching
        case .connecting, .discovering, .subscribing: return .connecting
        case .ready: return .connected
        }
    }

    private static func frameKind(for channel: LinkChannel) -> BLEFrameKind {
        switch channel {
        case .data: return .data
        case .control: return .control
        }
    }

    private static func characteristic(for channel: LinkChannel) -> UUID {
        switch channel {
        case .data: return NewMotionGATT.macToPhoneDataUUID
        case .control: return NewMotionGATT.macToPhoneControlUUID
        }
    }

    private static func channel(for characteristicUUID: UUID) -> LinkChannel? {
        switch characteristicUUID {
        case NewMotionGATT.phoneToMacDataUUID: return .data
        case NewMotionGATT.phoneToMacControlUUID: return .control
        default: return nil
        }
    }
}
