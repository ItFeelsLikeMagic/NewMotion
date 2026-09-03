# Development environment

Pinned toolchain, devices, commands, and the local log contract. Validated on
the host below on 2026-09-03. Update this file with a ticket when a pin changes.

## Pinned toolchain

| Input | Pin |
| --- | --- |
| Xcode | 27.0 beta, build `27A5252f` |
| Swift | 6.4 (`swiftlang-6.4.0.33.1`), strict concurrency `complete` |
| XcodeGen | Not installed. `scripts/generate.sh` falls back to `scripts/generate_fallback.py`. `project.yml` needs 2.38.0 or newer. |
| Deployment targets | iOS 18.0, macOS 15.0 |
| Default bundle prefix | `com.example.phoneremote` (in `project.yml` and the fallback generator) |

## Device matrix

| Role | Device | OS |
| --- | --- | --- |
| iPhone | dliao's iPhone 15 Pro Max (iPhone16,2) | iOS 27 beta |
| Mac host | Apple-silicon MacBook Pro (M1 Max) | macOS 27.0, build `26A5388g` |
| Simulators | iPhone 17, 17 Pro, 17 Pro Max, 17e, Air | iOS 27.0 runtime |

The phone UDID comes from `xcrun devicectl list devices`. The signing team ID comes
from Xcode Accounts. Both are passed only through the environment and never written
into the repo. Developer Mode is on. Keep the phone unlocked and on-screen for
`devicectl` install and DDI checks.

## Bundle prefix on the phone

The installed phone app uses prefix `com.davidliao.phoneremote`. It was built
with `PHONE_REMOTE_BUNDLE_PREFIX=com.davidliao.phoneremote`. Only the fallback
generator reads that variable, and only for the shared framework and the iOS
app. `debug-phone.sh` and `launch-phone.sh` default to the `com.example`
bundle ID, so set `PHONE_REMOTE_IOS_BUNDLE_ID=com.davidliao.phoneremote.ios`
for both. The Mac app stays `com.example.phoneremote.macos`.

## Commands

Simulator and macOS tests. No signing.

```bash
./scripts/generate.sh
./scripts/build.sh
PHONE_REMOTE_RUN_IOS_TESTS=1 ./scripts/test.sh
./scripts/fuzz-protocol.sh
```

`test.sh` picks the first available iPhone simulator. Set
`PHONE_REMOTE_IOS_DESTINATION='platform=iOS Simulator,id=<uuid>'` to choose one.

Phone install. The repo lives in iCloud Documents, so codesign fails on Finder
metadata there. Build outside the repo.

```bash
export IPHONE_UDID=<from devicectl list devices>
export PHONE_REMOTE_SIGNING=1
export PHONE_REMOTE_DEVELOPMENT_TEAM=<your team id>
export PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePhoneInstall
export PHONE_REMOTE_BUNDLE_PREFIX=com.davidliao.phoneremote
./scripts/install-phone.sh
```

Phone launch and log pull.

```bash
export IPHONE_UDID=<from devicectl list devices>
export PHONE_REMOTE_IOS_BUNDLE_ID=com.davidliao.phoneremote.ios
./scripts/launch-phone.sh
./scripts/debug-phone.sh
```

`debug-phone.sh` finds the phone by name (`dliao's iPhone`, override
`PHONE_REMOTE_DEVICE_NAME`) and copies to `/tmp/phoneremote-phone-debug`.
`logs-phone.sh` (sysdiagnose) fails with `DiagnoseError error 0` on this toolchain.

Mac install and logs.

```bash
export PHONE_REMOTE_SIGNING=1
export PHONE_REMOTE_DEVELOPMENT_TEAM=<your team id>
./scripts/install-mac.sh
./scripts/debug-mac.sh            # GET /state; pass /health for liveness
PHONE_REMOTE_LOG_WINDOW=5m ./scripts/logs-mac.sh
```

`install-mac.sh` replaces and launches `~/Applications/PhoneRemoteMac.app`. Grant
Accessibility to that copy only, then click Refresh Accessibility. Never open a
`/tmp` or DerivedData build.

Voice typing talks straight to a local `nemo-speech serve` WebSocket
(`~/.local/bin/nemo-speech`, Nemotron 0.6b GGUF from the Hugging Face hub cache).
At launch the Mac app checks `GET /health` on `PHONE_REMOTE_NEMO_PORT` (default
18766) and spawns the server itself when nothing answers; its output goes to
`/tmp/phoneremote-nemo-speech.log` and the child is stopped on quit. Punctuation
comes from Nemotron; there is no LLM cleanup step.
`PHONE_REMOTE_DEBUG_SERVER=0` disables the Mac debug server.

## CLI versus GUI

Everything above is scriptable. GUI-only steps: Apple ID and team selection in
Xcode, the iPhone "Trust This Computer" prompt, Developer Mode in Settings, the
macOS Accessibility toggle, and signing or device registration repair in Xcode.
Never commit a team ID, identity, or profile.

## Log and observability contract

- `MetricsRecorder` (Shared) is the only foundation logging API. It accepts message types, byte counts, sequence numbers, fixed enums, durations, and rates. It has no field for arbitrary strings.
- It tracks connection and lifecycle transitions, packet counts by type, sequence gaps, duplicates, retries, acknowledgements, heartbeat releases, audio gaps and duration, motion sample and output rates, and a latency histogram with fixed buckets: 0-4, 5-9, 10-24, 25-49, 50-99, 100-249, 250+ ms.
- iPhone debug log: `Documents/phoneremote-debug.jsonl` (events) and `Documents/phoneremote-debug-state.json` (latest snapshot). Events cover app init, scanner and camera state, camera diagnostics (`running`, `previewing`, `iso`, `lens`, `zoom`), BLE state, handshake steps, trust saves, reconnect, and push-to-talk press, send, release, and drop. Fields whose key contains `qr`, `secret`, `token`, `key`, `udid`, or `payload` are dropped before writing.
- Mac debug snapshot (`GET /state`): status, paused, accessibility, Bluetooth state, pairing progress, authenticated flag, offer state, whether a QR is showing, last failure and probe, visible peripheral name, last application message type, audio phase and counters (`audioFrames`, `audioSamples`, `audioMissingChunks`), app path, and paired display names with pair time.
- No log, snapshot, or metric may ever contain QR text, keys or handshake bytes, typed text, transcripts, audio bytes, or device identifiers.
- There is no remote analytics sink. A future local file sink must keep bounded retention (default seven days), write only structured fields, and offer a Clear diagnostics action. Uninstalling the app removes persisted diagnostics today.
