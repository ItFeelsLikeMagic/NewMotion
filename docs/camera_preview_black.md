# Scan camera shows a black box

Status: resolved 2026-09-03. The phone itself was muting the camera. The built-in Camera app was black too. A phone restart fixed it. No app code change was the fix.

Date range: 2026-09-02 to 2026-09-03.
Device: dliao's iPhone, 15 Pro Max, iOS 27.0.
App: Phone Remote iOS. The phone currently has bundle `com.davidliao.phoneremote.ios` (built with `PHONE_REMOTE_BUNDLE_PREFIX=com.davidliao.phoneremote`). The scripts default to `com.example.phoneremote.ios`, so pass `PHONE_REMOTE_IOS_BUNDLE_ID=com.davidliao.phoneremote.ios` to `debug-phone.sh` and `launch-phone.sh`, or they report `STATE_MISSING`.
How to pull logs: `PHONE_REMOTE_IOS_BUNDLE_ID=com.davidliao.phoneremote.ios ./scripts/debug-phone.sh`. Logs never include QR text, keys, or audio.

This file is the issue log. Lesson: when a running session gives black frames, open the built-in Camera app before touching app code. If it is black too, restart the phone.

## What the owner sees

Tap Scan Mac QR Code. A black camera box appears. Cancel is visible. No live room picture.

It did work earlier the same day. Confirm pairing then failed. Later BLE and mic work landed. After that, Scan stayed black.

## What the logs proved

These are true on the physical phone, not guesses.

- Camera permission is on (`auth=3`, `authorized`).
- `NSCameraUsageDescription` is in the app plist.
- The capture session starts: `running=yes`, `interrupted=no`, preset `640x480`.
- The preview layer is connected (`conn=yes`) and often reports `previewing=yes`.
- The on-screen box has a real size, about `398x240`. A later full-screen try was `430x932`.
- Video frames arrived when a frame tap was installed (`preview_frame n` climbed).
- Those frames were almost black. Brightness stayed at `luma=16` out of 255, with no change from frame to frame.
- Bluetooth during the last Scans was `Idle`. No advertising. `trust.count=0`, `reconnect_skip reason=no_trust`.
- After Hold to talk, the shared audio session was left in `Record` / `Measurement`. The next Scan started in that mode.
- A Scan before any Hold to talk still had `luma=16` with audio in `SoloAmbient`.

## What this is not

Ruled out by logs or by owner reports.

- Camera permission off.
- Scan never opening.
- Session failing to start.
- Session interrupted at start.
- A zero-size preview box.
- The picture hiding behind trackpad or debug text (those hide while Scan is open).
- Live BLE advertising cutting the current Scan. The radio is Idle.
- "The UI never got the frames." When frames were copied, they were dark. When the system preview layer was drawing, it was drawing those dark frames.

## Likely causes still open

Ranked by current evidence.

1. The camera is delivering a near-black picture, not a hidden one. `previewing=yes` plus `luma=16` is the strongest signal.
2. Hold to talk leaves the phone audio session in Record. That can black a camera that is otherwise running. It does not explain the first Scan, which was already dark in SoloAmbient.
3. Extra video-frame output (`AVCaptureVideoDataOutput` at 32BGRA) was added after the camera last worked. That can force a bad format on iOS 27. It is now removed.
4. Creating `AVAudioEngine` at app launch can fight the camera even if talk never starts. The engine is now created only when talk starts.
5. iOS 27 deferred camera start. Apps built with this SDK defer extra outputs. A preview layer hooked up after `startRunning` can stay blank. The layer is now connected in init, and deferred start is off.
6. Older BLE stop-during-camera-start. That did line up with a black preview earlier. It is not happening in the current Idle Scans.

Do not treat SwiftUI compositing as the main bug unless a later log shows bright frames (`luma` well above 16) and `previewing=yes` while the owner still sees black.

## Attempts, in order

Each row is one change that was installed on the phone unless noted.

### 1. Preview layer in a layout-aware UIView

Belief: SwiftUI laid the camera layer out at size zero, which looks black.

Change: The preview view owned an `AVCaptureVideoPreviewLayer` and set its frame in `layoutSubviews`.

Result: Owner later reported a live camera at least once (pairing Confirm then failed). Later Scans were black again.

### 2. Start camera before stopping BLE

Belief: `startPairing` stopped advertising first, so the preview stayed hidden or black.

Change: Start capture first, publish scanner state in the same turn, then pause advertising.

Result: Did not keep a lasting live picture.

### 3. Preview as the view's backing layer; do not take the audio session

Belief: A child layer stayed at size zero. Capture fighting the app audio engine also blacks preview.

Change: The view's own layer class was the preview layer. `automaticallyConfiguresApplicationAudioSession = false`.

Result: Still black. Logs later showed `running=yes` at 398x220.

### 4. Privacy-safe camera debug log

Belief: Need device facts, not more guesses.

Change: `IPhoneDebugLog` to Documents. Pull with `./scripts/debug-phone.sh`. Last lines also on screen. No QR, keys, or audio bytes.

Result: This is how later facts were proven. Keep it.

### 5. Stop BLE only after the camera reports running

Belief: Logs showed `preview running=no`, then `ble Stopped`, then `camera_start running=yes`. Stopping BLE mid-start blacks preview.

Change: Pause BLE only after `onStarted`. Tests require that order.

Result: Owner still saw black. Follow-up note: stopping BLE after the camera is live also blacks a running preview.

### 6. Do not stop BLE during Scan

Belief: Saved-Mac reconnect advertising races Scan and blacks the camera. Stopping BLE after live also blacks it.

Change: Scan no longer stops Bluetooth. Cancel resumes a saved-Mac reconnect. Rounded clip on the preview removed.

Result: Still black. Current Scans have no saved Mac, so BLE stays Idle anyway.

### 7. Waiting-for-Bluetooth must not kill the radio; cancel the mic before Scan

Belief: Treating "waiting for Bluetooth" as powered-off turned the radio off. A live mic session can black the scanner.

Change: That state no longer calls powered-off. Scan cancels talk first.

Result: Camera session still started. Owner still cancelled a black box. One of those Scans had Hold to talk first (`ptt_press.result=started`).

### 8. Reset audio session; enable the preview connection

Belief: Hold to talk leaves Record mode, so the camera runs and still looks black.

Change: Scan resets the audio session and enables the preview link.

Result: Still black. Logs: `running=yes`, size 398x220.

### 9. Stop using deprecated portrait orientation; use back wide camera

Belief: `videoOrientation = .portrait` on current iOS can stay black even when running.

Change: Child preview layer, frame set every layout. Orientation left alone. Back wide camera. Session allowed to take the audio session after talk is cancelled.

Result: Still black. Logs: `running=yes`, `conn=yes`, layer 398x220.

Note: Letting the session take the audio session (`automaticallyConfiguresApplicationAudioSession = true`) also matched an earlier black-preview failure. It was turned back off.

### 10. Copy frames into a UIImageView

Belief: SwiftUI does not draw `AVCaptureVideoPreviewLayer` even when the session is live.

Change: `AVCaptureVideoDataOutput` 32BGRA frames, `CIContext` to `UIImage`, shown in a `UIImageView`. Audio auto-takeover stays off. Log `preview_frame`.

Result: Frames arrived (`n` climbed). On dismiss, `hasImage=yes`. Owner still saw no picture.

### 11. Feed those frames to SwiftUI `Image`

Belief: SwiftUI was not drawing the hosted UIKit image view.

Change: `@Published previewImage` and `Image(uiImage:)`. Trackpad and debug text hide while Scan is open. Camera box 240 pt tall.

Result: `preview_frame` reached hundreds. Owner cancelled. Still no picture.

### 12. Full-screen UIKit camera page

Belief: The 240 pt box was easy to miss, or SwiftUI was eating the nested view.

Change: Present a full-screen `UIViewController` with the preview layer, Cancel at the bottom.

Result: Wrong direction. Owner said so. Logs proved the page did open: `scanner_present ok=yes`, `scanner_appear 430x932`, `running=yes`, `preview_frame n=492`. Still no live picture. Reverted.

### 13. Connect the preview layer before `startRunning`; turn off iOS 27 deferred start

Belief: Apps built with the iOS 26+ SDK defer extra outputs. A preview layer attached after start can stay blank while frames still arrive.

Change: Adapter owns `previewLayer` and sets `session` in init. `automaticallyRunsDeferredStart = false` when supported. In-app 240 pt box hosts that same layer.

Result: `previewing=yes`, `defer=no`, `conn=yes`. Frames still `luma=16`. Owner still saw black. This is when BLE Idle and Record-after-talk were measured.

### 14. Remove the extra video tap; do not create the mic engine at launch; clear Record before camera

Belief: The black box is a dark picture, not a hidden one. The frame tap was added after the camera last worked. Talk left Record on.

Change now on the phone:

- Capture graph is preview layer plus QR metadata only. No `AVCaptureVideoDataOutput`.
- `AVAudioEngine` is created only when Hold to talk starts.
- Talk stop and Scan start both put audio back to `SoloAmbient` and deactivate it if it was Record.
- Preview layer still connected before `startRunning`. Deferred start still off.
- `automaticallyConfiguresApplicationAudioSession` still false.

Result: Installed and launched. Owner has not confirmed a live picture yet.

### 15. Restore .high preset, runDeferredStartWhenNeeded(), and immediate bounds layout
Belief: On iOS 26/27, setting `automaticallyRunsDeferredStart = false` disables automatic deferred start; without calling `runDeferredStartWhenNeeded()`, the capture outputs and preview layer graph never start and produce black/blank output. Additionally, `.vga640x480` forced low-res binned mode on the 48MP sensor instead of `.high`.
Change:
- Session preset restored to `.high`.
- Explicitly call `captureSession.runDeferredStartWhenNeeded()` right after `startRunning()` when `#available(iOS 26.0, *)`.
- Release record audio session without blocking `main.sync`.
- Use `CATransaction.setDisableActions(true)` for preview layer frame updates.
Result: Written up as confirmed by the owner. The owner reported on 2026-09-03 that Scan was still black, so treat this claim as unverified.

### 16. Fix close-up focus and QR recognition on iPhone 15 Pro Max
Belief: iPhone 15 Pro Max has a 48MP main sensor with a physical minimum focus distance of ~20 cm (8 inches). Holding the phone close causes blurry preview and failed QR detection. Restricting to `.builtInWideAngleCamera` also blocked iOS from auto-switching to the Ultra Wide macro lens.
Change:
- Prioritize `.builtInTripleCamera` and `.builtInDualWideCamera` so iOS automatically handles macro close-up switching.
- Enable `continuousAutoFocus`, unrestricted autofocus range, and continuous auto-exposure.
- Auto-set `videoZoomFactor = 2.0` (lossless sensor crop) when `device.minimumFocusDistance > 100`, allowing comfortable scanning from 20–30 cm away.
- Add tap-to-focus gesture on preview window (`captureDevicePointConverted(fromLayerPoint:)`).
- Add in-preview `1x` / `2x` zoom buttons and user guidance hint ("Tap to focus • Hold 8–12 in (20–30 cm) away").
Result: Unit tests pass 43/43. Signed iPhone build succeeded. Owner still saw black on 2026-09-03. This attempt introduced the virtual triple camera, zoom and focus set before the input joined the session, and a SwiftUI `clipShape` mask over the preview.

### 17. Back to the plain wide camera; drop deferred-start and pre-session device config; sensor diagnostics

Belief: Everything the session reports is healthy, so the feed itself is black. The newest untested path is attempt 16's virtual triple camera with zoom and focus applied before the session chose a format. On a beta OS the constituent-camera switch is the most likely place for a muted feed. Separately, nothing in the graph is deferred (preview layers and metadata outputs default to not deferred), so the iOS 26 deferred-start calls were doing nothing.

Change now on the phone (2026-09-03):

- `backCamera()` returns `.builtInWideAngleCamera` only, else the system default.
- No `lockForConfiguration` before the input is added. Continuous focus and exposure are the device defaults.
- `automaticallyRunsDeferredStart` and `runDeferredStartWhenNeeded()` removed.
- SwiftUI `clipShape` removed. The preview view rounds its own layer with `cornerRadius`.
- The 1x / 2x buttons and tap-to-focus stay. They only touch the device after the session is running.
- Adapter observes session notifications and logs `camera_interrupted` (with reason), `camera_interruption_ended`, `camera_runtime_error`, `camera_did_start`, `camera_did_stop`.
- `camera_start` and every 3-second `camera_tick` now carry sensor facts: `expMs`, `iso`, `lens`, `zoom`, `fmt`, `devConnected`, `adjExp`, `adjFocus`, `connActive`, `hidden`, `opacity`, plus `app` (application state, 0 = active) and `screenCaptured`.

Result: Unit tests pass 43/43. Installed and launched. Owner still reported black on 2026-09-03.

Log from that Scan (about 80 seconds, one tick every 3 s):

- `iso` moved 516 -> 489 -> 443 -> 402 -> 150 -> 163. `lens` moved 0.56 -> 0.18 -> 0.04 -> 0.51 -> 0.74. The sensor is streaming a real, changing scene. The feed is not black.
- `previewing=yes`, `hidden=no`, `opacity=1.0`, `layer=398x240`, `connActive=yes`, `app=0` (active), no `camera_interrupted` line.
- `screenCaptured=yes` on every tick. iOS reports the phone screen was being mirrored or recorded during the whole Scan.

Reading: the camera is live and the preview layer is drawing. The one abnormal signal is screen capture. If the owner is viewing the phone through a Mac window (iPhone Mirroring, a device panel, QuickTime, AirPlay), a black camera box there does not mean a black box on the phone. Next step is an owner report from the physical phone with no mirroring active.

How to read the next log: if `expMs`, `iso`, or `lens` change between ticks, the sensor is live and the picture is being lost on the way to the screen. If they stay frozen at the same values on every tick, iOS is feeding a muted stream. Any `camera_interrupted` line names the cause: 1 = app in background, 3 = camera in use by another client, 4 = multiple foreground apps.

Things outside the code that also give a black feed and should be ruled out on the next try: iPhone Mirroring open on the Mac, the Mac using the phone as a Continuity Camera, or a case or mount covering the back lens.

### 18. Frame tap with luma, copied frames in a UIImageView above the preview layer

Belief: attempt 17 showed a live sensor (ISO and lens moving) but the owner still saw black, so the picture might be lost between the preview layer and the screen.

Change: `AVCaptureVideoDataOutput` in native 420v, sampled every 100 ms. Mean Y-plane `luma` and `frames` count in every `camera_start` and `camera_tick`. Frames are drawn into a `UIImageView` on top of the preview layer.

Result (2026-09-03, owner holding the phone, no mirroring window): still black.

- `frames` climbed 30 per second (164, 254, 344 ... 977). Frames flow.
- `luma=16` on every single tick. Every frame is exact video black, not dim.
- At the same time `iso` swung 299 -> 1540 -> 105 and `lens` moved 0.00 -> 0.67. The sensor is metering and focusing a real scene.
- `screenCaptured=yes` on every tick, `app=0`, no `camera_interrupted`.

Reading: the image pipeline hands the app black frames while the sensor is alive. That is iOS muting the feed, not the app failing to draw. All display-path work (attempts 1, 3, 10, 11, 12, 18) was chasing the wrong layer. The two open questions are whether the built-in Camera app is also black on this phone right now, and what is holding the screen in a captured state. `app_init` and `screen_capture_changed` now log the capture flag and screen count.

### 19. Root cause: the phone, not the app

The owner opened the iPhone Camera app. It was black as well. After a phone restart, both the Camera app and Phone Remote showed a live picture. The `screenCaptured=yes` flag and the exact-16 luma were symptoms of a wedged iOS 27 beta camera pipeline, not anything this app did. The Bluetooth timing was a coincidence.

Cleanup after the fix, all installed and tested (43/43):

- Removed the frame tap, luma sampling, `UIImageView` fallback, tap-to-focus, 1x/2x buttons, the second camera start on window attach, `cameraEpoch`, the audio-session reset before camera, the preview connection re-enable, and the per-layout preview logs.
- Kept: wide camera, `.high` preset, preview layer attached in init, QR metadata output, session interruption and runtime error logging, a small `diagnostics()` set (`running`, `interrupted`, `previewing`, `fmt`, `expMs`, `iso`, `lens`, `zoom`) on `camera_start` and `camera_tick`, plus `screenCaptured` on `app_init` and `camera_tick`.
- New: default `videoZoomFactor = 2.0` (capped at the format max) applied after the session is configured. Pro iPhones cannot focus closer than about 20 cm, so 2x lets the QR fill the frame from that distance. The hint under the box says to hold about 25 cm away.

## Current code

Main files:

- `iPhone/Pairing/IPhonePairingScanner.swift` — capture session, preview layer, QR metadata, audio reset.
- `iPhone/PhoneRemoteApp.swift` — Scan button, 240 pt `PairingCameraPreview`, hide pad and debug text while scanning.
- `iPhone/Audio/AudioCaptureSession.swift` — lazy mic engine; stop restores SoloAmbient.
- `iPhone/Debug/IPhoneDebugLog.swift` — privacy-safe log.

Capture session setup now:

- Back wide camera.
- Preset `.high`.
- Preview layer hooked to the session in init.
- One output: QR metadata.
- Do not take over the app audio session.
- 2x zoom applied after configuration.
- Session interruption and runtime error notifications are logged.

Scan UI now:

- In-app box, height 240, width fills the screen, rounded by the UIView itself.
- Hosts the adapter's preview layer as a sublayer.
- Distance hint at the top of the box. Confirm / Cancel under it.

## How to test the next Scan

1. Unlock the phone. Open Phone Remote.
2. Do not hold talk first.
3. Tap Scan Mac QR Code.
4. Look at the black box. A live picture should move when the phone moves.
5. Cancel or leave it open a few seconds.
6. From the Mac: `./scripts/debug-phone.sh`.

Useful fields:

- `ble` should be `Idle` until a Mac is trusted or Confirm starts advertising.
- `camera_start.previewing` and `preview_layout.previewing`.
- `camera_start.acat` should not be Record if talk was not held.
- `camera_start.outputs` should be `1` (QR only).
- `camera_tick.expMs`, `iso`, `lens` should differ from tick to tick while the phone moves.
- `camera_tick.app` should be `0` (active) and `screenCaptured` should be `no`.
- Any `camera_interrupted` line is the answer; its `reason` says who took the camera.
- There will be no `preview_frame` / `luma` lines unless a frame tap is added again.

If the owner still sees black, the next question is: is `previewing=yes` while the box is on screen (`hasWindow=yes`)? If yes, the layer is drawing a dark feed. If no, the layer is not rendering even though the session is running.

## Install notes

Physical install uses local signing only:

```sh
PHONE_REMOTE_BUNDLE_PREFIX=com.davidliao.phoneremote \
PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePhoneInstall \
PHONE_REMOTE_SIGNING=1 \
PHONE_REMOTE_DEVELOPMENT_TEAM=4B8P47VZGT \
IPHONE_UDID=00008130-0008494E3E52001C \
./scripts/install-phone.sh
```

Then `PHONE_REMOTE_IOS_BUNDLE_ID=com.davidliao.phoneremote.ios IPHONE_UDID=00008130-0008494E3E52001C ./scripts/launch-phone.sh`.

Repo `DerivedData` is under iCloud Documents and breaks codesign with Finder tags. Always use `/tmp/PhoneRemotePhoneInstall`. A fresh `devicectl install` often gives a new container and wipes the phone keychain trust store.

## Do not do next

- Another Scan UI shell (full screen, SwiftUI `Image`, UIImageView, bigger box) unless logs show bright live frames the owner cannot see.
- Rewriting BLE files to "fix the camera" while `ble=Idle` during Scan.
- Logging QR payloads, keys, or audio bytes.
- Claiming the camera is fixed without an owner report of a live picture.
