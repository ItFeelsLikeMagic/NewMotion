# Worker learnings

Rules that stop known regressions. Read before touching generation, transport,
pairing, input safety, or audio. No credentials, device identifiers, QR values, keys,
text, transcripts, or audio bytes here. Pins and commands: `docs/development_environment.md`.

## Toolchain and project generation

- `project.yml` is the source of truth. `scripts/generate.sh` uses XcodeGen when
  installed, else `scripts/generate_fallback.py`. Both must stay in sync. Why: two
  generators, one project.
- The fallback finds Swift files under `Shared`, `iPhone`, `Mac`, and `Tests` by itself.
  Do not hand-list files.
- Run `generate.sh` one at a time. Why: it deletes and recreates `.xcodeproj`, and two
  runs race on `xcshareddata/xcschemes`.
- Keep fallback file references repository-relative. A group with both a physical path
  and a repo-relative file path yields `Shared/Shared/...` duplicates.
- Only the fallback generator honors `PHONE_REMOTE_BUNDLE_PREFIX`, and only for the
  shared framework and iOS app. The macOS target and test bundles stay
  `com.example.phoneremote.*`. Why: XcodeGen reads `project.yml`, which hard-codes the
  prefix.
- Use `-scheme`, never a bare `-target`, whenever `-derivedDataPath` is passed. Why:
  Xcode 27 requirement.
- The shared framework pins iOS 18.0 and macOS 15.0 explicitly. Why: Xcode 27 otherwise
  defaults a framework to a newer SDK than the apps and it will not link.
- App test bundles need `ENABLE_TESTABILITY=YES` on the app plus `TEST_HOST` and
  `BUNDLE_LOADER`. Why: they compile but fail to link app symbols otherwise.
- Custom plists must set `CFBundleExecutable=$(EXECUTABLE_NAME)`. Why: simulator install
  fails with `MissingBundleExecutable`.
- Declare every usage description before the app creates the adapter: camera, Bluetooth,
  motion, microphone on iPhone; Accessibility and Bluetooth on Mac. Why: a missing
  `NSBluetoothAlwaysUsageDescription` killed the macOS test host before XCTest could
  attach.
- The embedded framework uses an `@rpath/...` install name and the apps carry
  `@executable_path/Frameworks` in `LD_RUNPATH_SEARCH_PATHS`. Why: the app launches then
  dies in the dynamic loader without it.
- Device and installed-Mac builds use `ENABLE_DEBUG_DYLIB=NO`. Why: the debug dylib is
  an extra unsigned binary; iOS kills the app and macOS never trusts it for
  Accessibility.
- Generated module names are `PhoneRemote_iOS` and `PhoneRemote_macOS`. XCTest imports
  must match exactly.

## Signing and install

- Signing is opt-in. `install-phone.sh` and `install-mac.sh` need
  `PHONE_REMOTE_SIGNING=1` plus `PHONE_REMOTE_DEVELOPMENT_TEAM` from the environment.
  Never write those values into the repo.
- Signed phone builds pass the phone as the explicit destination
  `platform=iOS,id=<udid>`. Why: a generic device build can pick a profile for a
  different phone and fail at install.
- `install-phone.sh` removes any other `*.phoneremote.ios` build from the device after it
  installs. Why: the bundle prefix comes from `PHONE_REMOTE_BUNDLE_PREFIX`, so one run without
  it leaves a second app with the same name and icon, and testing the wrong one wastes a session.
- Build device apps outside the repo (`PHONE_REMOTE_DERIVED_DATA=/tmp/...`). Why: the
  repo is in iCloud Documents and codesign fails on Finder metadata there.
- The Mac app you click must be `~/Applications/PhoneRemoteMac.app`, installed and
  signed with a local Apple Development identity by `install-mac.sh`. Never `open` a
  `/tmp` or DerivedData copy. Why: macOS grants Accessibility to one exact path and
  signature; adhoc or throwaway copies report `AXIsProcessTrusted()` false or look
  granted while the real app stays denied.
- `security find-identity -v -p codesigning` is the quick check for a local identity.
  Create or select it in Xcode Accounts. Never manufacture signing material. Signing a
  built app in place when CLI `xcodebuild` sees no account is a recovery probe only;
  keep the automatic path in the scripts.

## Swift 6 and framework boundaries

- Static collections of protocol or GATT value types must be `Sendable`. Add conformance
  only to immutable enums and structs. Never use `@unchecked Sendable` to hide mutable
  state.
- Use a literal CFDictionary key (`"AXTrustedCheckOptionPrompt"`) for the Accessibility
  prompt. Why: the imported global trips strict concurrency.
- Shared code is transport-neutral. Core Bluetooth, Core Graphics, Core Motion,
  AVFoundation, and transcription types live in app adapters. Shared code exchanges
  `Data`, UUIDs, fixed-width values, and protocol-owned enums.
- Callbacks that arrive off the main actor hop with `Task { @MainActor in ... }`. The
  motion sink already delivers on the main queue, so it uses `MainActor.assumeIsolated`.
  Why: an extra Task hop per sample queued up and the cursor lagged the longer the
  clutch was held.

## Protocol, BLE, and pairing invariants

- Protocol envelope cap is 8,192 bytes. Bounded byte fields cap at 2,048 bytes. Validate
  declared counts before reserving storage.
- BLE framing has a 16-byte header and must work at the 20-byte ATT minimum. Data and
  control characteristics stay separate. Queues and reassembly are bounded. Clear all
  partial and retry state on disconnect.
- Advertisement dictionaries use `CBUUID`, never Foundation `UUID`. Why: advertising
  silently omits the service and the Mac never sees the phone.
- Guard `stopScan`, `stopAdvertising`, and `removeAllServices` on `.poweredOn`. Why:
  calling them during init logs `API MISUSE` and corrupts later state.
- After an unpaired connect or discovery failure the Mac must resume scanning. Why:
  staying `disconnected` hides a later advertising phone.
- The iPhone never appears in macOS Bluetooth Settings. Pairing is in-app only: Mac
  shows QR, phone scans and confirms, phone advertises the custom service, Mac
  auto-connects.
- BLE readiness (service discovery, characteristic validation, notifications) is not
  authenticated readiness. Feature traffic waits for the X25519/HKDF/AEAD handshake.
  Keep the two states separate in code and in the UI.
- QR text is canonical bounded binary, unpadded Base64URL, with a `prqr1.` tag. Tokens
  are one-active, single-use, and expire within 120 seconds. Both the token store and
  its UI controller take an injected clock. Why: deterministic expiry tests.
- The QR secret and the Mac ephemeral private key never leave the Mac. The phone's hello
  carries only the pairing ID and public handshake material. The Mac consumes the offer
  atomically by pairing ID. No trust record is written until the authenticated finish
  succeeds.
- The QR pairing ID is the trust-record device ID on both sides. A Core Bluetooth
  identifier or display name is never identity.
- Trusted reconnect reuses the pairing ID and persisted identity keys with a fresh
  ephemeral handshake and no QR. It still yields a new authenticated session.
- Reject all-zero key material, altered transcripts or ciphertexts, wrong peer
  identities, replayed envelopes, and sequence rollback.
- Replay protection is a 64-slot sliding window, not a strict high-water mark, and it
  only advances after the AEAD tag verifies. Why: unreliable streams are encrypted on
  more than one queue, so the cursor path can take a later sequence number and reach the
  Mac first. Demanding a strict climb threw the frame that lost the race away, and a
  window that moved before verification would let a forged frame retire a sequence the
  real peer still owed.
- First-pairing order: scanner confirm, foreground-only advertising, BLE service ready,
  framed control `PairingClientHello`, Mac offer consumption and server hello, client
  finish, trust-record write, paired UI.
- The Mac pairing progress model is presentation-only (`waitingForLink`, `scanning`,
  `connecting`, `authenticating`, `paired`). Link state and session state stay separate.
  Why: a transient disconnect must not leave a false paired indicator.
- On macOS, `SecItemCopyMatching` rejects `kSecMatchLimitAll` combined with
  `kSecReturnData`. List with `kSecReturnAttributes`, validate each account UUID, then
  fetch each value with a single-record query. An attribute without a decodable value is
  inconsistent state: fail closed, never fall back to an unprotected store.

## Safety and feature boundaries

- Input policy is fail-closed. Required together: authenticated session, active state,
  unlocked and awake Mac, logged-in user, Accessibility exactly `.granted`. `unknown`
  Accessibility is not controllable.
- Every unsafe transition (disconnect, watchdog expiry, pause, startup, termination)
  funnels through one idempotent `releaseAllInputs`. The heartbeat watchdog is 500 ms.
  Reliable actions have finite retries.
- The Mac menu-bar UI calls `MacLifecycleCoordinator` and `SafeInputInjector` directly.
  Do not add a second pause or status boolean.
- The hotkey allowlist is explicit and atomic. Long-held modifier messages stay out
  until disconnect fault testing proves them safe.
- Zero-distance trackpad samples emit no pointer or scroll packets. Tap travel threshold
  is 6 logical points. Why: a real drag must not become a click.
- Motion pointer deltas map onto the existing Mac pointer injector. Do not add a second
  mouse path.
- Push-to-talk is local-only. Backgrounding, interruption, route change, cancel, or
  permission loss stops capture and resets chunking.
- Audio capture is 16 kHz mono Int16 with explicit sequence and sample metadata. The
  wire format is `VoiceStreamFrame` with the IMA ADPCM codec. The Mac decodes to PCM16,
  measures gaps and duplicates, and never hides them.
- Transcription runs locally through `NemotronRealtime.swift`, a Swift WebSocket client
  for `nemo-speech serve`. Neither side prints transcripts or audio bytes to logs.
- Cleanup runs locally too: `S1MiniNormalizer.swift` sends each final transcript to
  "S1-mini" by "Superwhisper" on the local Ollama before it is typed. The model is not a
  chat model. Send the trained system prompt, the control line, the empty think block,
  and temperature 0 through the raw endpoint, or it hallucinates. An empty result is a
  real answer for filler-only speech; every failure types the raw transcript instead.
- Word boosting is the only place keyword context belongs. `speech_contexts` on
  `session.update` must be sent before the first audio frame; the server refuses a
  session update once audio has started, and the boost list cannot be changed
  mid-stream. One strength covers every phrase, so a long noisy list drags ordinary
  speech toward screen furniture. Keep the list short.
- The Accessibility walk that gathers those words costs 17 ms in some apps and over two
  seconds in others (Notes). It runs on its own queue and its result is never waited on:
  a press is answered from the cache, and the walk it starts pays the next press. Keep it
  that way; anything added to that walk is paid on the worst app, not the average one.
- Accessibility reads any running app by process id. Measuring or reading one never
  requires activating it, and tooling must not move the user's windows to do so.
- A vocabulary cache hit means the word was spoken, not that it appeared on screen. A
  sighting only renews the short lease; the hit is what buys three hours and rank. Keep
  those two apart or the list fills with whatever the window happened to show.
- Transcript insertion is an explicit local action through the existing safe text-input
  path. Receiving a transcript never injects text by itself.
- The scanner never stops Bluetooth, and any advertising pause waits for the camera's
  `onStarted` (`Tests/iOS/PairingScannerTests.swift`). The scanner session is
  video-only; push-to-talk owns the audio session.

## Observability boundaries

- There are two shared observability APIs, and neither can see a payload. Keep it that
  way.
- `MetricsRecorder` records message types, counts, sizes, sequence outcomes, latency
  buckets, and lifecycle states. It has no field for strings, text, keys, or bytes. It
  is declared but not currently wired to anything in production.
- `LatencyTracker` records timings and counts only, in microseconds, over a 256-sample
  rolling window. It is never handed a payload, so nothing typed or said can reach a
  timing. Probes are registered in `Mac/Debug/MacLatencyProbes.swift` and
  `iPhone/Debug/PhoneLatency.swift`; see `docs/latency.md`.
- Never log payload bytes, QR material, keys, typed text, transcripts, audio, or device
  identifiers anywhere, including the Mac debug snapshot and the iPhone debug log.
- `IPhoneDebugLog.emit` drops any field whose key contains `qr`, `secret`, `token`,
  `key`, `udid`, or `payload`. Do not route around it.
- The Mac debug HTTP server is loopback-only. Default port 18765, next ports on bind
  failure. The bound port is written to `/tmp/phoneremote-mac-debug.json`;
  `debug-mac.sh` reads it from there. `PHONE_REMOTE_DEBUG_SERVER=0` disables it.

## Testing and hardware evidence

- `PhoneRemoteSharedTests` is the fastest deterministic check. It covers protocol,
  framing, transport, observability, pairing, and encrypted envelope integration with no
  Apple hardware.
- `scripts/fuzz-protocol.sh` runs the fixed 2,000-input decoder corpus with a fixed
  seed. Keep it bounded and deterministic. It logs no input bytes.
- Automated tests prove code paths, not radio, input, camera, or audio behavior on
  hardware.
- macOS XCTest may print `com.apple.linkd.autoShortcut` warnings and still pass. Unified
  log output includes CoreSpotlight and XPC noise. Filter by the Phone Remote process.
  Neither is a product failure.
- `devicectl list devices` showing `available (paired)` and Developer Mode enabled do
  not prove DDI readiness. Check `device info ddiServices` with the phone unlocked
  on-screen. A locked phone returns CoreDevice 12040.
- `devicectl` can report a successful launch while the process dies at once. Use
  `--console` or a delayed process query.
- `devicectl device sysdiagnose` (`logs-phone.sh`) can fail with
  `CoreDeviceCLISupport.DiagnoseError error 0` on this Xcode 27 build even when install
  and launch work. Treat it as a tooling blocker. An empty archive is not app-log
  evidence. Use `debug-phone.sh` instead.
- A dead camera or mic feed: open the built-in Apple app first. If it is dead there too,
  restart the phone. Session health flags cannot tell an app bug from an OS mute; moving
  `iso` and `lens` values in the debug log prove the sensor is alive.
- Never mark a ticket done from a compile, install, or launch. Update the ticket row and
  evidence in `docs/status.md`; hardware gate procedures and results live in
  `docs/verification/`. A ticket is done only when acceptance criteria and evidence are
  met.
