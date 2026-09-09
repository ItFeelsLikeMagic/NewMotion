#if canImport(SwiftUI)
import AVFoundation
import SwiftUI

#if canImport(NewMotionShared)
import NewMotionShared
#endif

/// A bar the finger can slide onto while the talk button is held.  Send lets
/// the words go as usual and presses Return after them; cancel throws the
/// utterance away.
enum PushToTalkZone: CaseIterable, Sendable {
    case send
    case cancel

    var title: String {
        switch self {
        case .send: return "Send"
        case .cancel: return "Cancel"
        }
    }

    var color: Color {
        switch self {
        case .send: return .green
        case .cancel: return .red
        }
    }

    var icon: String {
        switch self {
        case .send: return "paperplane.fill"
        case .cancel: return "trash.fill"
        }
    }

    var spokenRelease: String {
        switch self {
        case .send: return "Release to send and press Return"
        case .cancel: return "Release to cancel"
        }
    }
}

#if canImport(NewMotionShared)
extension PushToTalkZone {
    /// The same bar, named the way the wire names it, so the Mac's card can
    /// show what letting go would do.
    var armed: TranscriptPreviewArmed {
        switch self {
        case .send: return .send
        case .cancel: return .cancel
        }
    }
}
#endif

/// Owns push to talk end to end: the hold gesture, the microphone permission
/// it needs, and the one status line the user reads.  There is no separate
/// permission button; the first hold asks for the microphone and, if the
/// finger is still down when access is granted, starts the utterance.
@MainActor
final class PushToTalkController: ObservableObject {
    @Published private(set) var status = ""
    /// True from the moment the finger lands until it lifts.
    @Published private(set) var isHolding = false
    /// The bar the finger is over right now, if any.  Releasing here decides
    /// what becomes of the utterance.
    @Published private(set) var armedZone: PushToTalkZone?

    private let audio: LocalPushToTalkAudioController
    private let activity: @MainActor (String) -> Void
    /// Told the finger is down before the microphone is asked for, so the
    /// Mac's card can say it is listening without waiting on a permission
    /// prompt or an audio session.
    private let hold: @MainActor (Bool) -> Void
    /// Told which bar the finger lifted on, so the model can decide what
    /// follows the words this hold produced.
    private let lifted: @MainActor (PushToTalkZone?) -> Void
    /// Told the moment the finger crosses onto or off a bar, so the Mac's card
    /// lights the same bar this screen does instead of hearing about it on the
    /// next keepalive.
    private let armedChanged: @MainActor (PushToTalkZone?) -> Void
    private let logContext: @MainActor () -> [String: String]
    private var isHeld = false
    private var zoneFrames: [PushToTalkZone: CGRect] = [:]

    init(
        audio: LocalPushToTalkAudioController,
        activity: @escaping @MainActor (String) -> Void,
        hold: @escaping @MainActor (Bool) -> Void = { _ in },
        lifted: @escaping @MainActor (PushToTalkZone?) -> Void = { _ in },
        armedChanged: @escaping @MainActor (PushToTalkZone?) -> Void = { _ in },
        logContext: @escaping @MainActor () -> [String: String]
    ) {
        self.audio = audio
        self.activity = activity
        self.hold = hold
        self.lifted = lifted
        self.armedChanged = armedChanged
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
        armedChanged(zone)
    }

    func setZoneFrame(_ zone: PushToTalkZone, _ frame: CGRect) {
        zoneFrames[zone] = frame
    }

    private func covers(_ zone: PushToTalkZone, _ point: CGPoint) -> Bool {
        guard let frame = zoneFrames[zone], frame.width > 0, frame.height > 0 else { return false }
        return frame.contains(point)
    }

    /// The bar the finger lifted over, if any, so the caller can pick the buzz
    /// that goes with it.
    @discardableResult
    func released() -> PushToTalkZone? {
        isHeld = false
        isHolding = false
        let zone = armedZone
        armedZone = nil
        hold(false)
        lifted(zone)
        switch zone {
        case .cancel:
            audio.pushToTalkCancelled()
            status = ""
            activity("Push to talk cancelled")
            IPhoneDebugLog.emit("ptt_cancel", logContext())
        case .send:
            audio.pushToTalkReleased()
            activity("Push to talk released")
            IPhoneDebugLog.emit("ptt_send", ["zone": "send"])
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

/// Slid onto, never tapped: the hold owns the touch from press to release, so
/// a bar only reports where it is and the controller hit-tests it.  A layout
/// places it, and only while the finger is down: it takes the room the keys
/// give up, which is more than the talk button has beside it.
struct PushToTalkZoneBar: View {
    @ObservedObject var controller: PushToTalkController
    let zone: PushToTalkZone

    var body: some View {
        let armed = controller.armedZone == zone
        return Text(zone.title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(armed ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(armed ? zone.color : Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: armed)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                controller.setZoneFrame(zone, frame)
            }
    }
}

/// A local-only hold gesture.  The callback is never driven by a decoded
/// remote command; the audio controller itself also enforces that boundary.
struct PushToTalkButton: View {
    @ObservedObject var controller: PushToTalkController
    /// The height the microphone takes.  Upright it is pinned, so the bars a
    /// layout opens around it during a hold cannot shift the thumb's target;
    /// sideways it is left open and the mic takes what the column has spare.
    var micHeight: Double?
    @State private var isPressed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 6) {
            microphone

            if !controller.status.isEmpty {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var microphone: some View {
        Image(systemName: icon)
            .font(.system(size: 34, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: shortestMic, maxHeight: tallestMic)
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
    }

    private var shortestMic: Double { micHeight ?? RemoteKeyMetrics.clusterHeight }

    private var tallestMic: Double { micHeight ?? .infinity }

    /// The same icon as the bar the finger is over, so the button under the
    /// thumb and the bar it is sitting on say one thing.
    private var icon: String {
        if let zone = controller.armedZone { return zone.icon }
        return isPressed ? "waveform" : "mic.fill"
    }

    /// Green means the words are being recorded.  While a bar is armed the
    /// button takes that bar's colour instead.
    private var tint: Color {
        if let zone = controller.armedZone { return zone.color }
        return isPressed ? .green : .accentColor
    }

    private var spokenState: String {
        if let zone = controller.armedZone { return zone.spokenRelease }
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
