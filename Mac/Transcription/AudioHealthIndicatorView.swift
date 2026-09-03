#if os(macOS)
import SwiftUI

/// Presentation-only health indicator: duration, frame, and gap counts.
public struct AudioHealthIndicatorView: View {
    public let health: AudioHealthSnapshot

    public init(health: AudioHealthSnapshot) {
        self.health = health
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio \(health.durationSeconds, specifier: "%.1f") s")
            Text("Frames \(health.receivedFrames) · missing \(health.missingChunks)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}
#endif
