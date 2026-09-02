#if canImport(SwiftUI)
import SwiftUI

/// A local-only hold gesture.  The callback is never driven by a decoded
/// remote command; the audio controller itself also enforces that boundary.
public struct PushToTalkButton: View {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    @State private var isPressed = false

    public init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public var body: some View {
        Text(isPressed ? "Release to stop" : "Hold to talk")
            .frame(minWidth: 160, minHeight: 52)
            .contentShape(Rectangle())
            .background(isPressed ? Color.red : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onRelease()
                    }
            )
            .accessibilityLabel("Push to talk")
    }
}
#endif
