# Postmortem: Scan camera showed a black box

Dates: 2026-09-02 to 2026-09-03. Resolved.
Device: dliao's iPhone 15 Pro Max, iOS 27 beta. App: Phone Remote iOS.

## What happened

Tap Scan Mac QR Code. A black camera box appeared with Cancel under it. No live picture. It had worked earlier that day. It stayed black across 18 code attempts by two agents over about a day.

## Root cause

The phone itself had stopped delivering camera frames. The built-in iPhone Camera app was black too. A phone restart fixed both apps at once. No app code change was the fix. The Bluetooth work that landed at the same time was a coincidence.

The proof, from the app's debug log during one Scan:

- Frames arrived at 30 per second (`frames` climbed 164, 254, 344 ...).
- Every frame was exact video black: mean Y-plane `luma=16` on every tick.
- At the same time the sensor was metering a real scene: `iso` swung 299 to 1540 to 105 and `lens` moved 0.00 to 0.67.
- The session said `running=yes`, `previewing=yes`, `interrupted=no`, no interruption or runtime error notification.
- `UIScreen.isCaptured` was `yes` the whole time with no mirroring, AirPlay, or recording active.

That combination, live sensor plus black pixels plus no interruption, means iOS muted the feed below the app.

## Rule for next time

When a camera or microphone feed looks dead: open the matching built-in Apple app first. If it is dead there too, restart the phone. Only dig into app code if the system app works.

Session health flags (`running`, `previewing`, permission granted, connection active) all read fine while the OS mutes the feed. They cannot distinguish "app bug" from "phone bug". Pixel brightness plus sensor exposure numbers can.

## What was tried and ruled out

Every item below was installed on the phone and did not help. Keep this list so nobody repeats it.

- Preview layer sizing: layout-aware UIView, view-backed layer, frame set on every layout, `CATransaction` without actions, no SwiftUI clip mask. Not the cause.
- Display path: copying frames into a `UIImageView`, into a SwiftUI `Image`, a full-screen UIKit page. All black because the frames were black.
- Bluetooth: starting the camera before stopping advertising, stopping only after the camera reported running, never stopping during Scan. Bluetooth was Idle during the failing Scans.
- Audio: not taking over the app audio session, resetting Record back to SoloAmbient before Scan, creating the mic engine lazily. The first failing Scans were already in SoloAmbient.
- iOS 26 deferred start: turning `automaticallyRunsDeferredStart` off, calling `runDeferredStartWhenNeeded()`. Nothing in this graph is deferred (preview layers and metadata outputs default to not deferred), so both were no-ops.
- Camera choice: virtual triple camera with zoom and focus set before the input joined the session. Not the cause, and reverted because it was the newest untested path.
- Session preset 640x480 versus `.high`. Irrelevant.

## What the investigation left behind on purpose

- `IPhoneDebugLog`: privacy-safe event log in the app Documents folder, pulled with `scripts/debug-phone.sh`. Never contains QR text, keys, audio bytes, or device identifiers.
- `AVFoundationQRCodeCaptureAdapter.diagnostics()`: `running`, `interrupted`, `previewing`, `fmt`, `expMs`, `iso`, `lens`, `zoom`. Logged on `camera_start` and every 3-second `camera_tick` while Scan is open. Moving `iso` and `lens` prove the sensor is alive.
- `screenCaptured` on `app_init` and `camera_tick`. A `yes` with nothing mirroring is a sign the phone is in a bad state.
- `camera_interrupted` (with reason: 1 background, 3 another client, 4 multiple foreground apps), `camera_interruption_ended`, `camera_runtime_error` notifications.
- Ordering rule that stays: Scan never stops Bluetooth, and any advertising pause waits for the camera's `onStarted`. Tests cover this in `Tests/iOS/PairingScannerTests.swift`.

## Current scanner design

- Back wide camera, `.high` preset, preview layer attached to the session in init, one output (QR metadata).
- `automaticallyConfiguresApplicationAudioSession = false`. The session is video-only; push-to-talk owns the audio session.
- Default `videoZoomFactor = 2.0` after configuration. Pro iPhones cannot focus closer than about 20 cm, so 2x lets the QR fill the frame from that distance. The box shows a hint to hold about 25 cm away.
- The preview view is a plain `UIView` with the preview layer as a sublayer, rounded by its own `cornerRadius`.
