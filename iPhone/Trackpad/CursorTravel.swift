import Foundation

/// Cursor travel the radio has not taken yet.  The wire carries whole points,
/// so a packet rounds; rounding each packet on its own and discarding the rest
/// throws away up to half a point every time, which is most of a slow air-mouse
/// aim.  This keeps the fraction, and any travel past the wire limit, for the
/// next packet.
struct CursorTravel: Equatable {
    private(set) var x = 0.0
    private(set) var y = 0.0

    mutating func add(x deltaX: Double, y deltaY: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        x += deltaX
        y += deltaY
    }

    /// What one frame can carry right now.  Zero means the travel so far is
    /// still under half a point and should keep waiting.
    var wholePoints: (x: Int16, y: Int16) {
        (Self.clamped(x), Self.clamped(y))
    }

    mutating func take(x sentX: Int16, y sentY: Int16) {
        x -= Double(sentX)
        y -= Double(sentY)
    }

    mutating func clear() {
        x = 0
        y = 0
    }

    private static func clamped(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(min(max(value.rounded(), Double(Int16.min)), Double(Int16.max)))
    }
}
