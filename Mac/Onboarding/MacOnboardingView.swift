#if os(macOS)
import SwiftUI

/// One step per screen, in the app's stock macOS look.  Every pane shares
/// the same skeleton: a round icon, a title, one paragraph, then whatever
/// the step needs, with the step counter and a way out along the bottom.
struct MacOnboardingView: View {
    @ObservedObject var flow: MacOnboardingFlow
    @ObservedObject var model: MacRemoteAppModel
    let close: @MainActor () -> Void
    let bringToFront: @MainActor () -> Void
    let standAside: @MainActor (Bool) -> Void

    var body: some View {
        Group {
            switch flow.step {
            case .bluetooth:
                MacOnboardingBluetoothPane(flow: flow)
            case .accessibility:
                MacOnboardingAccessibilityPane(flow: flow)
            case .pair:
                MacOnboardingPairPane(flow: flow, model: model)
            case .done:
                MacOnboardingDonePane(model: model, close: close)
            }
        }
        .transition(.opacity)
        .frame(width: 640, height: 640)
        .background(flow.step.tint.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.35), value: flow.step)
        // Key again only once a dialog has been answered or a step is done:
        // any earlier would take the click from the dialog itself.  The
        // Accessibility ask opens its dialog beneath a floating panel, and
        // sends the user on to System Settings, so the panel stands aside
        // from the ask until the step is done.
        .onChange(of: flow.status) { old, new in
            standAside(new == .blocked(.accessibilityMissing))
            if old == .asking { bringToFront() }
        }
        .onChange(of: flow.step) { _, _ in
            standAside(false)
            bringToFront()
        }
    }
}

private extension MacOnboardingStep {
    /// One warm pastel per step, so a glance says which screen this is.
    var tint: Color {
        switch self {
        case .bluetooth: return Color(red: 1.0, green: 0.96, blue: 0.85)
        case .accessibility: return Color(red: 1.0, green: 0.91, blue: 0.90)
        case .pair: return Color(red: 1.0, green: 0.91, blue: 0.82)
        case .done: return Color(red: 0.96, green: 0.97, blue: 0.87)
        }
    }
}

// MARK: - Panes

private struct MacOnboardingBluetoothPane: View {
    @ObservedObject var flow: MacOnboardingFlow

    var body: some View {
        switch flow.status {
        case .waitingToAsk, .asking:
            MacOnboardingCentered(
                icon: .bluetooth,
                title: "Turn on Bluetooth",
                message: "Your iPhone talks to this Mac over Bluetooth. macOS will ask if NewMotion can use it."
            ) {
                MacOnboardingAllowDemo()
                    .padding(.top, 4)
            }
        case .granted:
            MacOnboardingCentered(icon: .done("checkmark"), title: "Bluetooth is on", message: "") { EmptyView() }
        case let .blocked(problem):
            MacOnboardingProblemPane(problem: problem, flow: flow)
        }
    }
}

private struct MacOnboardingAccessibilityPane: View {
    @ObservedObject var flow: MacOnboardingFlow

    /// The words never change once the dialog is up.  After the ask the
    /// app cannot tell "still in System Settings" from "clicked Deny", so
    /// the same screen gains a button that covers both, and nothing else.
    var body: some View {
        MacOnboardingCentered(
            icon: .accent("figure.stand"),
            title: "Let NewMotion control this Mac",
            message: "This is how your iPhone moves the cursor and types. Find NewMotion in the list and turn it on."
        ) {
            MacOnboardingSwitchDemo()
                .padding(.top, 4)
            // A fixed slot, so the button appearing moves nothing above it.
            VStack(spacing: 0) {
                switch flow.status {
                case .waitingToAsk, .asking, .granted:
                    EmptyView()
                case let .blocked(problem):
                    VStack(spacing: 14) {
                        Button("Open System Settings") { flow.openSettings() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                        if let path = problem.settingsPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .frame(height: 84, alignment: .top)
        }
    }
}

private struct MacOnboardingPairPane: View {
    @ObservedObject var flow: MacOnboardingFlow
    @ObservedObject var model: MacRemoteAppModel

    /// The three faces of this step.  Derived rather than switched on
    /// directly so the QR code never flashes back between Allow and the
    /// finished handshake: once a phone has a name, the code is history.
    private enum Phase: Equatable {
        case scan
        case approve(String)
        case pairing(String)
        case blocked(MacOnboardingProblem)
    }

    private var phase: Phase {
        if let name = model.pendingApprovalName { return .approve(name) }
        if case let .blocked(problem) = flow.status { return .blocked(problem) }
        if let name = model.pairingProgress.deviceName { return .pairing(name) }
        return .scan
    }

    var body: some View {
        Group {
            switch phase {
            case let .approve(name):
                MacOnboardingCentered(
                    icon: .accent("iphone"),
                    title: "Allow \(name)?",
                    message: "Once allowed, it can move the cursor and type on this Mac until you unpair it."
                ) {
                    HStack(spacing: 10) {
                        Button("Don't Allow") { model.denyPendingPhone() }
                            .keyboardShortcut(.cancelAction)
                        Button("Allow") { model.allowPendingPhone() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 10)
                }
            case let .pairing(name):
                MacOnboardingCentered(
                    icon: .accent("iphone"),
                    title: "Pairing with \(name)",
                    message: "Just a moment."
                ) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 10)
                }
            case let .blocked(problem):
                MacOnboardingProblemPane(problem: problem, flow: flow)
            case .scan:
                scanPane
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private var scanPane: some View {
        VStack(spacing: 8) {
            Text("Pair your iPhone")
                .font(.system(size: 28, weight: .bold))
            HStack(spacing: 36) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    if let image = model.pairingQRImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .accessibilityLabel("One-time pairing QR code")
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 16) {
                    MacOnboardingNumberedStep(number: 1) {
                        Text("Open ") + Text("NewMotion").fontWeight(.semibold) + Text(" on your iPhone")
                    }
                    MacOnboardingNumberedStep(number: 2) {
                        Text("Tap the ") + Text(Image(systemName: "gearshape")) + Text(" Settings button")
                    }
                    MacOnboardingNumberedStep(number: 3) {
                        Text("Tap ") + Text("Scan Mac QR Code").fontWeight(.semibold)
                    }
                    MacOnboardingNumberedStep(number: 4) {
                        Text("Point the camera at this code")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 28)
        }
        .padding(.horizontal, 48)
        .padding(.top, 36)
    }
}

private struct MacOnboardingDonePane: View {
    @ObservedObject var model: MacRemoteAppModel
    let close: @MainActor () -> Void

    var body: some View {
        let phone = model.pairingProgress.deviceName ?? "Your iPhone"
        MacOnboardingCentered(
            icon: .done("checkmark"),
            title: "You're all set",
            message: "\(phone) can now control this Mac. NewMotion lives in the menu bar. Open it there to pause, pair another iPhone, or run this setup again."
        ) {
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .padding(.top, 10)
        }
    }
}

/// The recovery state.  Each problem names what to do next, offers the
/// Settings pane where a switch exists, and a retry where one means
/// anything.  Both permission grants are noticed on their own, so every
/// pane here also says it will move on by itself.
private struct MacOnboardingProblemPane: View {
    let problem: MacOnboardingProblem
    @ObservedObject var flow: MacOnboardingFlow

    var body: some View {
        MacOnboardingCentered(icon: problem.icon, title: problem.title, message: problem.explanation) {
            HStack(spacing: 10) {
                if problem.canRetry {
                    Button("Try Again") { flow.promptNow() }
                }
                if problem.opensSettings {
                    Button("Open System Settings") { flow.openSettings() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 10)
            if let path = problem.settingsPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension MacOnboardingProblem {
    var icon: MacOnboardingIcon {
        switch self {
        case .bluetoothDenied, .bluetoothOff, .bluetoothUnsupported: return .bluetoothWarning
        case .accessibilityMissing: return .accent("figure.stand")
        case .pairingFailed: return .warning("iphone")
        }
    }

    var title: String {
        switch self {
        case .bluetoothDenied: return "Bluetooth is off for NewMotion"
        case .bluetoothOff: return "Bluetooth is turned off"
        case .bluetoothUnsupported: return "This Mac has no Bluetooth"
        case .accessibilityMissing: return "Let NewMotion control this Mac"
        case .pairingFailed: return "Pairing did not finish"
        }
    }

    var explanation: String {
        switch self {
        case .bluetoothDenied:
            return "No problem. Turn it on in System Settings, then quit and reopen NewMotion. This screen picks up where you left off."
        case .bluetoothOff:
            return "Turn Bluetooth on in Control Center or System Settings. This screen moves on by itself."
        case .bluetoothUnsupported:
            return "NewMotion needs a Bluetooth radio to hear your iPhone, and this Mac does not have one it can use."
        case .accessibilityMissing:
            return "Find NewMotion in the list and switch it on. This screen moves on by itself once it is on."
        case .pairingFailed:
            return "Try again to show a new code, then scan it with your iPhone."
        }
    }

    var settingsPath: String? {
        switch self {
        case .bluetoothDenied, .bluetoothOff: return "Privacy & Security › Bluetooth › NewMotion"
        case .accessibilityMissing: return "Privacy & Security › Accessibility › NewMotion"
        case .bluetoothUnsupported, .pairingFailed: return nil
        }
    }
}

// MARK: - Shared pieces

private enum MacOnboardingIcon {
    case accent(String)
    case warning(String)
    case done(String)
    case bluetooth
    case bluetoothWarning
}

private struct MacOnboardingIconView: View {
    let icon: MacOnboardingIcon

    var body: some View {
        switch icon {
        case let .accent(symbol):
            filled(color: .accentColor) { glyph(symbol) }
        case let .done(symbol):
            filled(color: .green) { glyph(symbol) }
        case .bluetooth:
            filled(color: .accentColor) { rune(.white) }
        case let .warning(symbol):
            outlined { glyph(symbol) }
        case .bluetoothWarning:
            outlined { rune(.orange) }
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 34, weight: .medium))
    }

    private func rune(_ color: Color) -> some View {
        MacOnboardingBluetoothRune()
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .frame(width: 26, height: 36)
    }

    private func filled<Glyph: View>(color: Color, @ViewBuilder glyph: () -> Glyph) -> some View {
        glyph()
            .foregroundStyle(.white)
            .frame(width: 80, height: 80)
            .background(Circle().fill(color))
            .shadow(color: color.opacity(0.3), radius: 10, y: 8)
    }

    private func outlined<Glyph: View>(@ViewBuilder glyph: () -> Glyph) -> some View {
        glyph()
            .foregroundStyle(.orange)
            .frame(width: 80, height: 80)
            .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(Circle().stroke(.orange, lineWidth: 2))
    }
}

/// The skeleton every permission pane and the end screen share.
private struct MacOnboardingCentered<Action: View>: View {
    let icon: MacOnboardingIcon
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 18) {
            MacOnboardingIconView(icon: icon)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 6)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action()
        }
        .padding(.horizontal, 56)
        .padding(.top, 12)
    }
}

/// The permission dialog the user is about to see, with the pointer
/// landing on Allow and pressing it, so the right button is known before
/// the real one appears.  Drawn to match the macOS card: the blue tile
/// with a hand badge, the question, and two equal pill buttons.
private struct MacOnboardingAllowDemo: View {
    @State private var pointerOffset = CGSize(width: 70, height: 44)
    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.2, green: 0.55, blue: 0.95))
                .frame(width: 52, height: 52)
                .overlay {
                    MacOnboardingBluetoothRune()
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 30)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(red: 0.2, green: 0.55, blue: 0.95)))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 6, y: 6)
                }
                .padding(.bottom, 8)
            Text("Allow \u{201C}NewMotion\u{201D} to use Bluetooth?")
                .font(.system(size: 15, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("NewMotion uses Bluetooth to connect to your paired iPhone.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Don\u{2019}t Allow")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Text("Allow")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(isPressed ? 0.18 : 0.08)))
                    .scaleEffect(isPressed ? 0.96 : 1)
                    .overlay {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.black)
                            .shadow(color: .white, radius: 1)
                            .offset(x: 8, y: 6)
                            .offset(pointerOffset)
                    }
            }
            .font(.system(size: 14))
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 270)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
        .accessibilityLabel("The macOS Bluetooth dialog, with the pointer clicking Allow")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.easeInOut(duration: 0.6)) { pointerOffset = .zero }
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.easeOut(duration: 0.1)) { isPressed = true }
                try? await Task.sleep(for: .seconds(0.15))
                withAnimation(.easeIn(duration: 0.15)) { isPressed = false }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.5)) { pointerOffset = CGSize(width: 70, height: 44) }
            }
        }
    }
}

/// The Bluetooth mark, drawn: it is a trademark and not in SF Symbols.
private struct MacOnboardingBluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.27))
        path.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY + h * 0.73))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w, y: rect.minY + h * 0.27))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.73))
        return path
    }
}

/// The System Settings row the user is about to see, with its switch
/// flipping on and off so the picture says what to do there.
private struct MacOnboardingSwitchDemo: View {
    @State private var isOn = false

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            Text("NewMotion")
                .font(.system(size: 17))
            Spacer()
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.12))
                .frame(width: 44, height: 26)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .padding(2)
                }
        }
        .padding(.horizontal, 18)
        .frame(width: 340, height: 60)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        )
        .accessibilityLabel("The NewMotion row in System Settings, with its switch turned on")
        .task {
            // Off for a beat, on for longer, so the on state reads as the goal.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeInOut(duration: 0.3)) { isOn = true }
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeInOut(duration: 0.3)) { isOn = false }
            }
        }
    }
}

private struct MacOnboardingNumberedStep<Content: View>: View {
    let number: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            content()
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#endif
