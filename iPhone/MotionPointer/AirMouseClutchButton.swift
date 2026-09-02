#if canImport(SwiftUI)
import SwiftUI

/// Hold-to-activate clutch UI.  Releasing it freezes motion and the session
/// resets its orientation reference on the next activation.
public struct AirMouseClutchButton: View {
    private let onClutchChanged: (Bool) -> Void
    @State private var held = false

    public init(onClutchChanged: @escaping (Bool) -> Void) {
        self.onClutchChanged = onClutchChanged
    }

    public var body: some View {
        Text(held ? "Air Mouse Active" : "Hold for Air Mouse")
            .frame(minWidth: 180, minHeight: 52)
            .contentShape(Rectangle())
            .background(held ? Color.green : Color.secondary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held else { return }
                        held = true
                        onClutchChanged(true)
                    }
                    .onEnded { _ in
                        guard held else { return }
                        held = false
                        onClutchChanged(false)
                    }
            )
            .accessibilityLabel("Air mouse clutch")
    }
}
#endif
