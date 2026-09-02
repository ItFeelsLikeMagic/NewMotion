#if os(macOS)
import SwiftUI

/// Presentation-only health indicator.  It displays aggregate levels and gap
/// counts, never PCM bytes or transcript content.
public struct AudioHealthIndicatorView: View {
    public let health: AudioHealthSnapshot

    public init(health: AudioHealthSnapshot) {
        self.health = health
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio \(health.durationSeconds, specifier: "%.1f") s")
            ProgressView(value: health.lastLevel)
                .accessibilityLabel("Microphone level")
            Text("Chunks \(health.receivedChunks) · gaps \(health.missingChunks) · late \(health.lateChunks)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}
#endif
