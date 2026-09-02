import Foundation

/// 4-bit IMA ADPCM for 16 kHz mono speech. Each encoded payload is
/// self-describing so a dropped BLE frame does not poison the next one.
public struct IMAADPCMEncoder: Equatable, Sendable {
    public private(set) var predictor: Int32 = 0
    public private(set) var stepIndex: Int = 0

    public init() {}

    public mutating func reset() {
        predictor = 0
        stepIndex = 0
    }

    public mutating func encode(_ samples: [Int16]) -> Data {
        let startPredictor = predictor
        let startIndex = stepIndex
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity((samples.count + 1) / 2)
        var pending: UInt8?
        for sample in samples {
            let nibble = encodeSample(Int32(sample))
            if let low = pending {
                nibbles.append(low | (nibble << 4))
                pending = nil
            } else {
                pending = nibble
            }
        }
        if let low = pending {
            nibbles.append(low)
        }

        var payload = Data(capacity: 4 + nibbles.count)
        let bits = UInt16(bitPattern: Int16(clamping: startPredictor))
        payload.append(UInt8(bits & 0xff))
        payload.append(UInt8(bits >> 8))
        payload.append(UInt8(clamping: startIndex))
        payload.append(0)
        payload.append(contentsOf: nibbles)
        return payload
    }

    private mutating func encodeSample(_ sample: Int32) -> UInt8 {
        let step = IMAADPCM.stepTable[stepIndex]
        var diff = sample - predictor
        var nibble: UInt8 = 0
        if diff < 0 {
            nibble = 8
            diff = -diff
        }
        var remain = diff
        var vpdiff = step >> 3
        if remain >= step {
            nibble |= 4
            remain -= step
            vpdiff += step
        }
        if remain >= step >> 1 {
            nibble |= 2
            remain -= step >> 1
            vpdiff += step >> 1
        }
        if remain >= step >> 2 {
            nibble |= 1
            vpdiff += step >> 2
        }
        if (nibble & 8) != 0 {
            predictor -= vpdiff
        } else {
            predictor += vpdiff
        }
        predictor = min(Int32(Int16.max), max(Int32(Int16.min), predictor))
        stepIndex = min(88, max(0, stepIndex + IMAADPCM.indexTable[Int(nibble)]))
        return nibble
    }
}

public enum IMAADPCM {
    public static func decode(payload: Data, sampleCount: Int) -> [Int16] {
        guard sampleCount > 0, payload.count >= 4 else { return [] }
        let bytes = Array(payload)
        let predBits = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var predictor = Int32(Int16(bitPattern: predBits))
        var stepIndex = Int(bytes[2])
        stepIndex = min(88, max(0, stepIndex))
        let nibbles = bytes.dropFirst(4)
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)
        for byte in nibbles {
            if samples.count >= sampleCount { break }
            samples.append(decodeNibble(byte & 0x0f, predictor: &predictor, stepIndex: &stepIndex))
            if samples.count >= sampleCount { break }
            samples.append(decodeNibble(byte >> 4, predictor: &predictor, stepIndex: &stepIndex))
        }
        if samples.count > sampleCount {
            samples.removeLast(samples.count - sampleCount)
        }
        return samples
    }

    private static func decodeNibble(_ nibble: UInt8, predictor: inout Int32, stepIndex: inout Int) -> Int16 {
        let step = stepTable[stepIndex]
        var vpdiff = step >> 3
        if (nibble & 4) != 0 { vpdiff += step }
        if (nibble & 2) != 0 { vpdiff += step >> 1 }
        if (nibble & 1) != 0 { vpdiff += step >> 2 }
        if (nibble & 8) != 0 {
            predictor -= vpdiff
        } else {
            predictor += vpdiff
        }
        predictor = min(Int32(Int16.max), max(Int32(Int16.min), predictor))
        stepIndex = min(88, max(0, stepIndex + indexTable[Int(nibble)]))
        return Int16(clamping: predictor)
    }

    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1_060, 1_166, 1_282, 1_411, 1_552, 1_707, 1_878, 2_066, 2_272, 2_499, 2_749,
        3_024, 3_327, 3_660, 4_026, 4_428, 4_871, 5_358, 5_894, 6_484, 7_132, 7_845,
        8_630, 9_493, 10_442, 11_487, 12_635, 13_899, 15_289, 16_818, 18_500, 20_350,
        22_385, 24_623, 27_086, 29_794, 32_767
    ]

    static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
}
