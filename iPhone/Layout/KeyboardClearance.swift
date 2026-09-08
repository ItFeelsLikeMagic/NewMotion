#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit

/// Keeps content clear of the system keyboard by measuring how far the
/// keyboard reaches over it.
///
/// SwiftUI's own avoidance cannot do this here.  The app's text responder is a
/// hidden view rather than a field on screen, so the layout is moved by an
/// amount that has nothing to do with where the controls floating on the
/// trackpad ended up, and the keyboard is left covering them.
private struct KeyboardClearance: ViewModifier {
    /// Where the top of the keyboard is in screen coordinates.  Off the bottom
    /// of the world while there is no keyboard, so the overlap is zero.
    @State private var keyboardTop: Double = .infinity

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .padding(.bottom, max(0, proxy.frame(in: .global).maxY - keyboardTop))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTop = frame.minY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardTop = .infinity
        }
    }
}

extension View {
    /// Holds this view above the keyboard, however much of it the keyboard
    /// would otherwise cover.
    func clearOfKeyboard() -> some View {
        modifier(KeyboardClearance())
    }
}
#endif
