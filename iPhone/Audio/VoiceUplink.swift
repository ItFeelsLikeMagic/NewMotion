import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// Turns PCM chunks into encrypted BLE fragments on the voice queue.  Every
/// method except `setSession` must be called on that queue.  `deliver` is the
/// only hop to the main thread and receives all fragments of one message so
/// the transport can drop the message whole instead of sending part of it.
final class VoiceUplink: @unchecked Sendable {
    /// Main-thread application messages count up from 1.  Voice messages use
    /// the upper half of the ID space so the Mac never reassembles two
    /// concurrent messages under one ID.
    private static let firstMessageID: UInt32 = 1 << 31

    var deliver: (@Sendable ([Data], VoiceStreamFlags) -> Void)?

    private let queue: DispatchQueue
    private var session: PairingSession?
    private var maximumValueLength = BLEFramingLimits.minimumValueLength
    private var streamID: SessionID?
    private var encoder = IMAADPCMEncoder()
    private var sequence: UInt32 = 0
    private var nextMessageID = firstMessageID
    private var streamStartedAt: TimeInterval = 0
    private var peak: Int16 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func setSession(_ session: PairingSession?, maximumValueLength: Int) {
        queue.async {
            self.session = session
            self.maximumValueLength = maximumValueLength
        }
    }

    func beginStream() {
        streamID = try? SessionID(bytes: (0..<SessionID.byteCount).map { _ in UInt8.random(in: 0...255) })
        encoder.reset()
        sequence = 0
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        peak = 0
        send(samples: [], flags: .start)
    }

    func send(samples: [Int16]) {
        peak = max(peak, samples.reduce(0) { max($0, $1 == Int16.min ? Int16.max : abs($1)) })
        send(samples: samples, flags: [])
    }

    func endStream() {
        send(samples: [], flags: .end)
        streamID = nil
    }

    private func send(samples: [Int16], flags: VoiceStreamFlags) {
        let flagName = flags.contains(.end) ? "end" : (flags.contains(.start) ? "start" : "data")
        guard let streamID, let session else {
            IPhoneDebugLog.emit("ptt_drop", ["reason": "no_session", "flags": flagName])
            return
        }
        // The sequence advances even when the transport later drops the
        // message, so the Mac can count the gap.
        let frameSequence = sequence
        sequence &+= 1
        let messageID = nextMessageID
        nextMessageID = messageID == UInt32.max ? Self.firstMessageID : messageID + 1
        do {
            let frame = try VoiceStreamFrame(
                flags: flags,
                streamID: streamID,
                sequence: frameSequence,
                sampleCount: UInt16(samples.count),
                payload: samples.isEmpty ? Data() : encoder.encode(samples)
            )
            let fragments = try session.wrapBinary(
                frame.encode(),
                messageType: MessageType.audioChunk.rawValue,
                messageID: messageID,
                maximumValueLength: maximumValueLength,
                reliable: flags.contains(.end)
            )
            if flags.contains(.start) || flags.contains(.end) {
                // Peak level proves the microphone delivered sound, without logging audio.
                IPhoneDebugLog.emit("ptt_frame", ["seq": "\(frameSequence)", "flags": flagName, "peak": "\(peak)"])
            } else if frameSequence == 1 {
                // Press-to-first-audio latency; speech before this point is lost.
                let ms = Int((ProcessInfo.processInfo.systemUptime - streamStartedAt) * 1000)
                IPhoneDebugLog.emit("ptt_first_audio", ["ms": "\(ms)"])
            }
            guard let deliver else { return }
            hopToMain { deliver(fragments, flags) }
        } catch {
            IPhoneDebugLog.emit("ptt_drop", ["reason": "encode_fail", "flags": flagName])
        }
    }

    /// The background path drains the voice queue with `sync` from the main
    /// thread; an async hop there would land after the transport is torn down.
    private func hopToMain(_ work: @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
