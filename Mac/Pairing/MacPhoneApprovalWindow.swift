#if os(macOS)
import AppKit
import SwiftUI

/// A floating Allow/Deny prompt for a phone that has just scanned the QR
/// code. It lives outside the menu bar popover because the popover is closed
/// while the user is holding the phone, and the phone is waiting on this
/// answer. Nothing here blocks: the buttons call back and the window closes.
@MainActor
final class MacPhoneApprovalWindow {
    private var window: NSWindow?

    func show(deviceName: String, onAllow: @escaping @MainActor () -> Void, onDeny: @escaping @MainActor () -> Void) {
        close()
        let content = MacPhoneApprovalView(deviceName: deviceName, onAllow: onAllow, onDeny: onDeny)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Phone Remote"
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct MacPhoneApprovalView: View {
    let deviceName: String
    let onAllow: @MainActor () -> Void
    let onDeny: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow \(deviceName) to control this Mac?", systemImage: "iphone.radiowaves.left.and.right")
                .font(.headline)
            Text("It scanned this Mac's pairing code. Once allowed, it can move the cursor and type on this Mac until you unpair it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't Allow", action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: onAllow)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
#endif
