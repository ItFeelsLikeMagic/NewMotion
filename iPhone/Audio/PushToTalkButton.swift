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
    /// True from the moment the finger lands until it lifts; the cancel
    /// targets are on screen for exactly this long.
    @Published private(set) var isHolding = false
    /// The target the finger is over right now, if any.  Releasing here
    /// throws the utterance away.
    @Published private(set) var armedZone: PushToTalkZone?

    private let audio: LocalPushToTalkAudioController
    private let activity: @MainActor (String) -> Void
    /// Told the finger is down before the microphone is asked for, so the
    /// Mac's card can say it is listening without waiting on a permission
    /// prompt or an audio session.
    private let hold: @MainActor (Bool) -> Void
    private let logContext: @MainActor () -> [String: String]
    private var isHeld = false
    private var zoneFrames: [PushToTalkZone: CGRect] = [:]

    init(
        audio: LocalPushToTalkAudioController,
        activity: @escaping @MainActor (String) -> Void,
        hold: @escaping @MainActor (Bool) -> Void = { _ in },
        logContext: @escaping @MainActor () -> [String: String]
    ) {
        self.audio = audio
        self.activity = activity
        self.hold = hold
        self.logContext = logContext
    }

    func pressed() {
        isHeld = true
        isHolding = true
        armedZone = nil
        hold(true)
        start()
    }

    /// Reported in window coordinates, which is the space the zone frames are
    /// measured in.  The touch keeps arriving after it leaves the button.
    func dragged(to point: CGPoint) {
        guard isHeld else { return }
        let zone = PushToTalkZone.allCases.first { covers($0, point) }
        guard zone != armedZone else { return }
        armedZone = zone
        Haptics.play(zone == nil ? .gestureEnded : .gestureBegan)
    }

    func setZoneFrame(_ zone: PushToTalkZone, _ frame: CGRect) {
        zoneFrames[zone] = frame
    }

    /// The targets are drawn as circles, so the finger has to be inside the
    /// disc the frame encloses rather than anywhere in its square.
    private func covers(_ zone: PushToTalkZone, _ point: CGPoint) -> Bool {
        guard let frame = zoneFrames[zone], frame.width > 0, frame.height > 0 else { return false }
        let x = (point.x - frame.midX) / (frame.width / 2)
        let y = (point.y - frame.midY) / (frame.height / 2)
        return x * x + y * y <= 1
    }

    /// The target the finger lifted over, if any, so the caller can pick the
    /// buzz that goes with it.
    @discardableResult
    func released() -> PushToTalkZone? {
        isHeld = false
        isHolding = false
        let zone = armedZone
        armedZone = nil
        hold(false)
        switch zone {
        case .some:
            audio.pushToTalkCancelled()
            status = ""
            activity("Push to talk cancelled")
            IPhoneDebugLog.emit("ptt_cancel", logContext())
        case .none:
            audio.pushToTalkReleased()
            activity("Push to talk released")
        }
        return zone
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                // Fills the gap between the two key clusters, at their full
                // height, so it is the easiest thing on screen to hit.
                .frame(maxWidth: .infinity, minHeight: RemoteKeyMetrics.clusterHeight)
                .contentShape(Rectangle())
                .background(tint)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { PushToTalkTouchSurface(press: press, drag: controller.dragged(to:), release: release) }
                // A cancelled touch (incoming call, app switcher) reaches the
                // touch view, but a suspended app never delivers one at all.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { release() }
                }
                .accessibilityLabel(spokenState)
                .onAppear { Haptics.prepare() }

            if !controller.status.isEmpty {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// The same icon as the target the finger is over, so the button under the
    /// thumb and the circle it is sitting on say one thing.
    private var icon: String {
        guard controller.armedZone == nil else { return "trash.fill" }
        return isPressed ? "waveform" : "mic.fill"
    }

    /// Green means the words are being recorded.  Red is only ever cancel, and
    /// it is the red of the circle the finger has landed on.
    private var tint: Color {
        guard controller.armedZone == nil else { return .red }
        return isPressed ? .green : .accentColor
    }

    private var spokenState: String {
        guard controller.armedZone == nil else { return "Release to cancel" }
        return isPressed ? "Recording" : "Push to talk"
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        Haptics.play(.press)
        controller.pressed()
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        let zone = controller.released()
        Haptics.play(zone == nil ? .release : .press)
    }
}
#endif
