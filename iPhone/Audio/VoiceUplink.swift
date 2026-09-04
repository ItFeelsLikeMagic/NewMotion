import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

/// Turns PCM chunks into sealed voice messages on the voice queue.  Every
/// method except `setSession` must be called on that queue.  `deliver` is the
/// only hop to the main thread and carries one whole message, so the link can
/// drop it whole instead of sending part of it.
final class VoiceUplink: @unchecked Sendable {
    var deliver: (@Sendable (Data, VoiceStreamFlags) -> Void)?

    private let queue: DispatchQueue
    private var session: PairingSession?
    private var streamID: SessionID?
    private var encoder = IMAADPCMEncoder()
    private var sequence: UInt32 = 0
    private var streamStartedAt: TimeInterval = 0
    private var peak: Int16 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func setSession(_ session: PairingSession?) {
        queue.async {
            self.session = session
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

    /// Says where the finger is hovering, mid-stream.  The Mac holds its typing
    /// while an edit is on the table and warms the editor model.
    func sendIntent(edit: Bool) {
        send(samples: [], flags: edit ? [.intent, .edit] : .intent)
    }

    /// Ends the stream the other way: the Mac drops everything it has for this
    /// stream instead of transcribing it.
    func cancelStream() {
        send(samples: [], flags: [.end, .cancel])
        streamID = nil
    }

    /// Ends the stream as an instruction: the Mac edits the field with these
    /// words instead of typing them.
    func endStreamAsEdit() {
        send(samples: [], flags: [.end, .edit])
        streamID = nil
    }

    private func send(samples: [Int16], flags: VoiceStreamFlags) {
        let clock = LatencyClock()
        let flagName = Self.name(for: flags)
        guard let streamID, let session else {
            PhoneLatency.voiceEncode.recordRefusal()
            IPhoneDebugLog.emit("ptt_drop", ["reason": "no_session", "flags": flagName])
            return
        }
        // The sequence advances even when the link later drops the message, so
        // the Mac can count the gap.
        let frameSequence = sequence
        sequence &+= 1
        do {
            let frame = try VoiceStreamFrame(
                flags: flags,
                streamID: streamID,
                sequence: frameSequence,
                sampleCount: UInt16(samples.count),
                payload: samples.isEmpty ? Data() : encoder.encode(samples)
            )
            let sealed = try session.encrypt(
                plaintext: frame.encode(),
                messageType: MessageType.audioChunk.rawValue
            )
            PhoneLatency.voiceEncode.record(microseconds: clock.elapsedMicroseconds)
            if flags.contains(.start) || flags.contains(.end) {
                // Peak level proves the microphone delivered sound, without logging audio.
                IPhoneDebugLog.emit("ptt_frame", ["seq": "\(frameSequence)", "flags": flagName, "peak": "\(peak)"])
            } else if frameSequence == 1 {
                // Press-to-first-audio latency; speech before this point is lost.
                let ms = Int((ProcessInfo.processInfo.systemUptime - streamStartedAt) * 1000)
                IPhoneDebugLog.emit("ptt_first_audio", ["ms": "\(ms)"])
            }
            guard let deliver else { return }
            hopToMain { deliver(sealed, flags) }
        } catch {
            PhoneLatency.voiceEncode.recordRefusal()
            IPhoneDebugLog.emit("ptt_drop", ["reason": "encode_fail", "flags": flagName])
        }
    }

    private static func name(for flags: VoiceStreamFlags) -> String {
        if flags.contains(.intent) { return flags.contains(.edit) ? "intentEdit" : "intentType" }
        if flags.contains(.cancel) { return "cancel" }
        if flags.contains(.end) { return flags.contains(.edit) ? "endEdit" : "end" }
        return flags.contains(.start) ? "start" : "data"
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
