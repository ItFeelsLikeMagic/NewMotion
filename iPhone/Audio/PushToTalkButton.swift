#if canImport(SwiftUI)
import AVFoundation
import SwiftUI

/// Owns push to talk end to end: the hold gesture, the microphone permission
/// it needs, and the one status line the user reads.  There is no separate
/// permission button; the first hold asks for the microphone and, if the
/// finger is still down when access is granted, starts the utterance.
@MainActor
final class PushToTalkController: ObservableObject {
    @Published private(set) var status = ""

    private let audio: LocalPushToTalkAudioController
    private let activity: @MainActor (String) -> Void
    private let logContext: @MainActor () -> [String: String]
    private var isHeld = false

    init(
        audio: LocalPushToTalkAudioController,
        activity: @escaping @MainActor (String) -> Void,
        logContext: @escaping @MainActor () -> [String: String]
    ) {
        self.audio = audio
        self.activity = activity
        self.logContext = logContext
    }

    func pressed() {
        isHeld = true
        start()
    }

    func released() {
        isHeld = false
        audio.pushToTalkReleased()
        activity("Push to talk released")
    }

    private func start() {
        guard isHeld else { return }
        audio.pushToTalkPressed { [weak self] result in
            Task { @MainActor [weak self] in self?.handle(result) }
        }
    }

    private func handle(_ result: AudioCaptureStartResult) {
        let resultName: String
        switch result {
        case .started:
            resultName = "started"
            // iOS mutes the microphone system-wide while the screen is
            // mirrored or recorded; the capture keeps running but is silent.
            status = UIScreen.main.isCaptured ? "Microphone is blocked while your screen is mirrored or recorded." : ""
            activity("Push to talk active")
        case .permissionDenied:
            resultName = "permissionDenied"
            requestMicrophone()
        case .notForeground:
            resultName = "notForeground"
            activity("Push to talk unavailable while backgrounded")
        case .failed:
            resultName = "failed"
            activity("Microphone could not start")
        }
        var fields = logContext()
        fields["result"] = resultName
        fields["screenCaptured"] = UIScreen.main.isCaptured ? "yes" : "no"
        IPhoneDebugLog.emit("ptt_press", fields)
    }

    /// Asking once the microphone is already denied returns false without
    /// showing anything, so send the user to Settings instead.
    private func requestMicrophone() {
        guard AVAudioApplication.shared.recordPermission == .undetermined else {
            status = "Microphone is off. Turn it on in Settings."
            return
        }
        status = "Asking for microphone access…"
        audio.requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    status = isHeld ? "" : "Microphone ready. Hold to talk."
                    start()
                } else {
                    status = "Microphone is off. Turn it on in Settings."
                }
            }
        }
    }
}

/// A local-only hold gesture.  The callback is never driven by a decoded
/// remote command; the audio controller itself also enforces that boundary.
struct PushToTalkButton: View {
    @ObservedObject var controller: PushToTalkController
    @State private var isPressed = false
    // Kept alive across presses; an unprepared generator takes about 100 ms to
    // fire, which is the delay this is meant to cover.
    @State private var haptics = UIImpactFeedbackGenerator(style: .medium)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 6) {
            Text(isPressed ? "Release to stop" : "Hold to talk")
                .frame(minWidth: 160, minHeight: 52)
                .contentShape(Rectangle())
                .background(isPressed ? Color.red : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { PushToTalkTouchSurface(press: press, release: release) }
                // A cancelled touch (incoming call, app switcher) reaches the
                // touch view, but a suspended app never delivers one at all.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { release() }
                }
                .accessibilityLabel("Push to talk")
                .onAppear { haptics.prepare() }

            if !controller.status.isEmpty {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        haptics.impactOccurred()
        haptics.prepare()
        controller.pressed()
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        haptics.impactOccurred(intensity: 0.5)
        haptics.prepare()
        controller.released()
    }
}
#endif
