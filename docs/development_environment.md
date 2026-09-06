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
| Default bundle prefix | `com.davidliao.phoneremote` (in `project.yml` and the fallback generator) |

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

`com.davidliao.phoneremote` is now the default everywhere: the fallback
generator, `project.yml`, `debug-phone.sh`, and `launch-phone.sh` all agree with
what the phone carries, so no environment variable is needed for the normal
loop. `PHONE_REMOTE_BUNDLE_PREFIX` still overrides the whole prefix for a
different signing account, and `PHONE_REMOTE_IOS_BUNDLE_ID` still overrides the
one ID the phone scripts talk to.

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

The macOS tests are hosted by the real Mac app, so every run launches it. Under
XCTest the host is inert: an `InertCentralManagerAdapter` instead of Core
Bluetooth, an in-memory trust store instead of the login Keychain, and no
speech server or debug server. Unsigned rebuilds change the binary hash, so
those two subsystems would otherwise raise a system approval dialog on every
run. `PHONE_REMOTE_INERT_HOST=1` forces the same behaviour outside tests.

The two tests that use the real Keychain are opt-in:

```bash
PHONE_REMOTE_KEYCHAIN_TESTS=1 ./scripts/test.sh
```

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

Voice typing needs nothing on the Mac. The iPhone turns speech into text
with Apple's on-device recogniser and sends the finished sentence as text,
so there is no speech server, no Ollama, and no model to install. The Mac's
only share of it is the front-window word walk it pushes to the phone as a
boost list. `PHONE_REMOTE_DEBUG_SERVER=0` disables the Mac debug server.

The first launch on a given iPhone downloads Apple's language model. Settings
shows the percentage while it comes down; until it says Ready, a press records
but produces nothing.

## Shipping the Mac companion

`install-mac.sh` is the local development copy and is signed for development.
It is not distributable: another Mac refuses it.

`./scripts/package-mac.sh` makes the copy other people can run. It builds
Release, signs with Developer ID and the hardened runtime, gets a secure
timestamp, sends it to Apple for notarization, staples the ticket on, and
leaves `PhoneRemoteMac.app` and `PhoneRemoteMac.zip` in `build/dist`. The zip
is what to upload somewhere; the stapled ticket means it opens on a Mac that
is offline and has never heard of it.

It needs two things that are not in this repository and must not be:

- `PHONE_REMOTE_DEVELOPMENT_TEAM`, the ten-character team id.
- `PHONE_REMOTE_NOTARY_PROFILE`, the name of a notarytool keychain profile.
  Create it once with `xcrun notarytool store-credentials`, using an
  app-specific password from appleid.apple.com.

A "Developer ID Application" certificate is required and is not the same as
the "Apple Development" one the local install uses. Only the paid Developer
Program issues it; Xcode's Settings, Accounts, Manage Certificates panel is
where it is created. `--skip-notarize` exercises everything up to Apple.

Signing runs in a temporary directory rather than in the repository. This
tree sits under a synced folder whose file provider stamps
`com.apple.FinderInfo` back onto every file as fast as it is cleared, and
`codesign --verify` refuses to look past that.

## CLI versus GUI

Everything above is scriptable. GUI-only steps: Apple ID and team selection in
Xcode, the iPhone "Trust This Computer" prompt, Developer Mode in Settings, the
macOS Accessibility toggle, and signing or device registration repair in Xcode.
Never commit a team ID, identity, or profile.

## Log and observability contract

- `LatencyTracker` (Shared) is the shared observability API. It accepts a stage name and a duration or a refusal, and nothing else: no strings, no bytes, no payload. It keeps a 256-sample rolling window per stage and reports median, p95, worst, and a running refusal count.
- Timings are recorded in microseconds, because most stages are under a millisecond. `refused=` and its attempt count are running totals while the timings are a rolling window, so the recent refusal rate is the difference between two readings.
- iPhone debug log: `Documents/phoneremote-debug.jsonl` (events) and `Documents/phoneremote-debug-state.json` (latest snapshot). Events cover app init, scanner and camera state, camera diagnostics (`running`, `previewing`, `iso`, `lens`, `zoom`), link state, handshake steps, trust saves, reconnect, push-to-talk press, send, release, and drop, and a `latency` event every five seconds carrying the five phone probes (`linkData`, `linkCtrl`, `input`, `held`, `rtt`). Fields whose key contains `qr`, `secret`, `token`, `key`, `udid`, or `payload` are dropped before writing.
- Mac debug snapshot (`GET /state`): status, paused, accessibility, `link` and `linkKind`, pairing progress, authenticated flag, offer state, whether a QR is showing, last failure and probe, `peerName`, last application message type, `cursorEvents`, `keyPostMs`, `vocabulary` (the last boost walk), `deleteScrub`, a `latency` array of six `LatencySummary` entries, app path, and paired display names with pair time.
- No log, snapshot, or metric may ever contain QR text, keys or handshake bytes, typed text, transcripts, audio bytes, or device identifiers.
- There is no remote analytics sink. A future local file sink must keep bounded retention (default seven days), write only structured fields, and offer a Clear diagnostics action. Uninstalling the app removes persisted diagnostics today.
