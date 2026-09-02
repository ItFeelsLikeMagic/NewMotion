import Foundation

#if canImport(PhoneRemoteShared)
import PhoneRemoteShared

public enum SharedMotionProtocolAdapterError: Error, Equatable, Sendable {
    case valueOutOfRange
    case invalidSampleRate
}

public enum SharedMotionProtocolAdapter {
    public static func payload(
        for delta: MotionPointerDelta,
        sampleRateHz: Double
    ) throws -> MessagePayload {
        guard sampleRateHz.isFinite, (1...100).contains(sampleRateHz) else {
            throw SharedMotionProtocolAdapterError.invalidSampleRate
        }
        guard delta.x.isFinite, delta.y.isFinite,
              delta.x >= Double(Int16.min), delta.x <= Double(Int16.max),
              delta.y >= Double(Int16.min), delta.y <= Double(Int16.max) else {
            throw SharedMotionProtocolAdapterError.valueOutOfRange
        }
        return .motionPointerDelta(MotionPointerDeltaPayload(
            deltaX: Int16(delta.x.rounded()),
            deltaY: Int16(delta.y.rounded()),
            sampleRateHz: UInt16(sampleRateHz.rounded())
        ))
    }
}
#endif
