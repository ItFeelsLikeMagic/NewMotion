import Foundation

public struct MacAudioPCMChunk: Equatable, Sendable {
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let samplePosition: UInt64
    public let sampleCount: UInt32
    public let pcmLittleEndian: Data
    public let level: Double

    public init?(
        sequence: UInt64,
        timestamp: TimeInterval,
        samplePosition: UInt64,
        sampleCount: UInt32,
        pcmLittleEndian: Data,
        level: Double = 0
    ) {
        guard timestamp.isFinite,
              sampleCount > 0,
              pcmLittleEndian.count == Int(sampleCount) * 2,
              pcmLittleEndian.count <= 4_096,
              level.isFinite,
              level >= 0,
              level <= 1 else { return nil }
        self.sequence = sequence
        self.timestamp = timestamp
        self.samplePosition = samplePosition
        self.sampleCount = sampleCount
        self.pcmLittleEndian = pcmLittleEndian
        self.level = level
    }
}

public enum AudioChunkDisposition: Equatable, Sendable {
    case accepted
    case duplicate
    case late
    case malformed
    case gapFilled(samples: UInt64)
    case gapTooLarge(samples: UInt64)
}

public struct AudioHealthSnapshot: Equatable, Sendable {
    public let receivedChunks: UInt64
    public let receivedSamples: UInt64
    public let missingChunks: UInt64
    public let missingSamples: UInt64
    public let duplicateChunks: UInt64
    public let lateChunks: UInt64
    public let durationSeconds: Double
    public let lastLevel: Double

    public init(
        receivedChunks: UInt64,
        receivedSamples: UInt64,
        missingChunks: UInt64,
        missingSamples: UInt64,
        duplicateChunks: UInt64,
        lateChunks: UInt64,
        durationSeconds: Double,
        lastLevel: Double
    ) {
        self.receivedChunks = receivedChunks
        self.receivedSamples = receivedSamples
        self.missingChunks = missingChunks
        self.missingSamples = missingSamples
        self.duplicateChunks = duplicateChunks
        self.lateChunks = lateChunks
        self.durationSeconds = durationSeconds
        self.lastLevel = lastLevel
    }
}

public protocol PCMDataSink: AnyObject {
    func begin(sampleRate: Int, channels: Int, bitsPerSample: Int) throws
    func append(_ bytes: Data) throws
    func finish() throws
    func discard()
}

public enum AudioReassemblerError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case invalidFormat
    case sinkFailure
}

/// Streams audio to a WAV sink while explicitly accounting for gaps,
/// duplicates, and late chunks.  Missing sample positions are represented by
/// bounded silence so WAV duration remains meaningful without unbounded RAM.
public final class AudioPCMReassembler {
    public let sampleRate: Int
    public let maxSyntheticGapSamples: UInt64

    private let sink: PCMDataSink
    private var started = false
    private var expectedSequence: UInt64?
    private var expectedSamplePosition: UInt64?
    private var receivedChunks: UInt64 = 0
    private var receivedSamples: UInt64 = 0
    private var missingChunks: UInt64 = 0
    private var missingSamples: UInt64 = 0
    private var duplicateChunks: UInt64 = 0
    private var lateChunks: UInt64 = 0
    private var lastLevel = 0.0

    public init(
        sink: PCMDataSink,
        sampleRate: Int = 16_000,
        maxSyntheticGapSamples: UInt64 = 16_000 * 10
    ) {
        self.sink = sink
        self.sampleRate = max(1, sampleRate)
        self.maxSyntheticGapSamples = max(1, maxSyntheticGapSamples)
    }

    public var health: AudioHealthSnapshot {
        AudioHealthSnapshot(
            receivedChunks: receivedChunks,
            receivedSamples: receivedSamples,
            missingChunks: missingChunks,
            missingSamples: missingSamples,
            duplicateChunks: duplicateChunks,
            lateChunks: lateChunks,
            durationSeconds: Double(receivedSamples + missingSamples) / Double(sampleRate),
            lastLevel: lastLevel
        )
    }

    public func start() throws {
        guard !started else { throw AudioReassemblerError.alreadyStarted }
        do {
            try sink.begin(sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
            started = true
        } catch {
            throw AudioReassemblerError.sinkFailure
        }
    }

    @discardableResult
    public func receive(_ chunk: MacAudioPCMChunk) -> AudioChunkDisposition {
        guard started else { return .malformed }
        guard chunk.pcmLittleEndian.count == Int(chunk.sampleCount) * 2,
              chunk.pcmLittleEndian.count <= 4_096 else { return .malformed }

        if let expectedSequence, chunk.sequence < expectedSequence {
            duplicateChunks += 1
            if chunk.sequence + 1 == expectedSequence { return .duplicate }
            lateChunks += 1
            return .late
        }

        if expectedSequence == nil {
            expectedSequence = chunk.sequence
            expectedSamplePosition = chunk.samplePosition
        }

        var disposition: AudioChunkDisposition = .accepted
        if let expectedSequence, chunk.sequence > expectedSequence {
            missingChunks += chunk.sequence - expectedSequence
        }

        guard let expectedSamplePosition else { return .malformed }
        if chunk.samplePosition < expectedSamplePosition {
            lateChunks += 1
            return .late
        }

        let gap = chunk.samplePosition - expectedSamplePosition
        if gap > 0 {
            missingSamples += gap
            if gap <= maxSyntheticGapSamples {
                do {
                    try sink.append(Self.silence(samples: gap))
                } catch {
                    return .malformed
                }
                disposition = .gapFilled(samples: gap)
            } else {
                disposition = .gapTooLarge(samples: gap)
            }
        }

        do {
            try sink.append(chunk.pcmLittleEndian)
        } catch {
            return .malformed
        }
        receivedChunks += 1
        receivedSamples += UInt64(chunk.sampleCount)
        lastLevel = chunk.level
        self.expectedSequence = chunk.sequence + 1
        self.expectedSamplePosition = chunk.samplePosition + UInt64(chunk.sampleCount)
        return disposition
    }

    public func finish() throws -> AudioHealthSnapshot {
        guard started else { throw AudioReassemblerError.notStarted }
        do {
            try sink.finish()
            started = false
            return health
        } catch {
            throw AudioReassemblerError.sinkFailure
        }
    }

    public func disconnect(discard: Bool = false) {
        guard started else { return }
        if discard {
            sink.discard()
        } else {
            try? sink.finish()
        }
        started = false
    }

    private static func silence(samples: UInt64) -> Data {
        let count = Int(min(samples, UInt64(Int.max / 2))) * 2
        return Data(repeating: 0, count: count)
    }
}

/// Writes a PCM WAV stream using a placeholder header and patches sizes at
/// finalization.  It is intended for local test artifacts, not permanent
/// recording storage.
public final class WAVFileSink: PCMDataSink {
    public let url: URL
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private var sampleRate = 16_000
    private var channels = 1
    private var bitsPerSample = 16

    public init(url: URL) {
        self.url = url
    }

    public func begin(sampleRate: Int, channels: Int, bitsPerSample: Int) throws {
        guard handle == nil, sampleRate > 0, channels > 0, bitsPerSample == 16 else {
            throw AudioReassemblerError.invalidFormat
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle?.write(contentsOf: Self.header(
            dataBytes: 0,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        ))
    }

    public func append(_ bytes: Data) throws {
        guard let handle else { throw AudioReassemblerError.notStarted }
        try handle.write(contentsOf: bytes)
        bytesWritten += UInt64(bytes.count)
    }

    public func finish() throws {
        guard let handle else { throw AudioReassemblerError.notStarted }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(
            dataBytes: bytesWritten,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        ))
        try handle.close()
        self.handle = nil
        bytesWritten = 0
    }

    public func discard() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        try? FileManager.default.removeItem(at: url)
    }

    private static func header(dataBytes: UInt64, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let riffSize = UInt32(min(UInt64(UInt32.max), 36 + dataBytes))
        let dataSize = UInt32(min(UInt64(UInt32.max), dataBytes))
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(riffSize, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(channels), to: &data)
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(byteRate), to: &data)
        appendLE(UInt16(blockAlign), to: &data)
        appendLE(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize, to: &data)
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

public final class InMemoryPCMDataSink: PCMDataSink {
    public private(set) var bytes = Data()
    public private(set) var format: (sampleRate: Int, channels: Int, bitsPerSample: Int)?
    public private(set) var finished = false
    public private(set) var discarded = false

    public init() {}

    public func begin(sampleRate: Int, channels: Int, bitsPerSample: Int) throws {
        format = (sampleRate, channels, bitsPerSample)
        bytes.removeAll(keepingCapacity: true)
        finished = false
        discarded = false
    }

    public func append(_ bytes: Data) throws {
        guard format != nil, !finished, !discarded else { throw AudioReassemblerError.notStarted }
        self.bytes.append(bytes)
    }

    public func finish() throws {
        guard format != nil, !discarded else { throw AudioReassemblerError.notStarted }
        finished = true
    }

    public func discard() {
        discarded = true
        bytes.removeAll(keepingCapacity: true)
    }
}

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared

public extension MacAudioPCMChunk {
    /// Shared audio payloads carry sequence and sample position themselves.
    init?(shared payload: AudioChunkPayload, timestamp: TimeInterval, level: Double = 0) {
        self.init(
            sequence: UInt64(payload.chunkIndex),
            timestamp: timestamp,
            samplePosition: payload.samplePosition,
            sampleCount: UInt32(payload.pcm.bytes.count / 2),
            pcmLittleEndian: Data(payload.pcm.bytes),
            level: level
        )
    }
}
#endif
