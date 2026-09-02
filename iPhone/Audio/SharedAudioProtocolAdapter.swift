import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared

public enum SharedAudioProtocolAdapterError: Error, Equatable, Sendable {
    case invalidSampleCount
}

public enum SharedAudioProtocolAdapter {
    /// Envelope timestamp is supplied by the transport layer. PCM is sent as
    /// raw samples; the Mac reconstructs sample position from the payload.
    public static func payload(
        for chunk: CapturedPCM16Chunk,
        streamID: SessionID,
        isLast: Bool = false
    ) throws -> MessagePayload {
        guard chunk.sampleCount > 0,
              chunk.pcmLittleEndian.count == Int(chunk.sampleCount) * 2 else {
            throw SharedAudioProtocolAdapterError.invalidSampleCount
        }
        return .audioChunk(try AudioChunkPayload(
            streamID: streamID,
            chunkIndex: UInt32(clamping: chunk.sequence),
            pcm: Array(chunk.pcmLittleEndian),
            samplePosition: chunk.samplePosition,
            isLast: isLast
        ))
    }
}
#endif
