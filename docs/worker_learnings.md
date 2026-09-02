# Reusable implementation learnings

This file is for future coding workers. It records decisions and failure modes
that are easy to miss when resuming the prototype. It contains no credentials,
device identifiers, QR values, keys, typed text, transcripts, or audio bytes.

## Toolchain and project generation

- Xcode 27 requires scheme-based `xcodebuild` invocations when
  `-derivedDataPath` is supplied. Use `-scheme`, not a bare `-target`, in the
  normal scripts.
- XcodeGen is not guaranteed to be installed. `scripts/generate.sh` prefers
  XcodeGen and otherwise runs the checked-in deterministic
  `scripts/generate_fallback.py`. The fallback discovers Swift files below
  `Shared`, `iPhone`, `Mac`, and `Tests` automatically.
- The fallback generator removes and recreates the ignored `.xcodeproj`; run
  `scripts/generate.sh` sequentially when multiple checks are in flight. Two
  concurrent generators can race while recreating `xcshareddata/xcschemes`.
- Keep repository-relative file references in the fallback project. Giving a
  group both a physical path and a repository-relative file path creates
  duplicated paths such as `Shared/Shared/Protocol/...`.
- Xcode 27 can default a framework target to a newer SDK deployment version
  than the apps. Explicitly set the shared framework to iOS 18/macOS 15 so it
  can link into both app targets.
- Application test bundles need both `ENABLE_TESTABILITY=YES` on the app
  target and an app `TEST_HOST`/`BUNDLE_LOADER`; otherwise the tests may compile
  but fail to link with undefined app symbols.
- Custom app plists must include `CFBundleExecutable=$(EXECUTABLE_NAME)`. A
  simulator can build an app without it, but installation/test launch fails
  with `MissingBundleExecutable`.
- The current reproducible loop is:

  ```sh
  ./scripts/generate.sh
  ./scripts/build.sh
  PHONE_REMOTE_RUN_IOS_TESTS=1 ./scripts/test.sh
  ```

  `scripts/test.sh` chooses the first available iPhone simulator by UUID. Set
  `PHONE_REMOTE_IOS_DESTINATION` when a specific simulator is required.
- `scripts/fuzz-protocol.sh` runs the fixed 2,000-input decoder corpus used by
  PRO-002. Keep it bounded and deterministic so failures are reproducible and
  no untrusted bytes need to enter logs.
- The Mac app's menu-bar UI should call `MacLifecycleCoordinator` and
  `SafeInputInjector` directly; do not add a second pause/status boolean. The
  iPhone UI can expose local gestures while dropping feature output until the
  authenticated BLE coordinator is connected.
- If an app instantiates Core Bluetooth, camera, motion, or microphone adapters
  during UI setup, declare the matching usage descriptions first. Missing
  `NSBluetoothAlwaysUsageDescription` caused the macOS test host to terminate
  before XCTest could connect; missing camera/motion strings would fail later
  on a physical iPhone.
- `AXIsProcessTrusted()` stays false for adhoc linker-signed Debug Mac builds
  that use Xcode's debug dylib stub, even when Accessibility is toggled on.
  Build the Mac app with `ENABLE_DEBUG_DYLIB=NO`, sign it with a local Apple
  Development identity, and run it from a stable path such as `~/Applications`.
  Use `./scripts/install-mac.sh` for that install/launch. Never `open` a `/tmp`
  or DerivedData `PhoneRemoteMac.app`; macOS grants Accessibility to that exact
  path and signature, so a throwaway copy looks enabled while the live app is
  still denied.
- Keep BLE readiness separate from authenticated readiness in the UI. The Mac
  central may scan at launch, while the iPhone peripheral starts advertising
  only from the scanner's one-confirmation callback; neither state authorizes
  input until the pairing handshake completes.
- The iPhone will not appear in macOS Bluetooth Settings. Pairing is in-app
  only: the Mac shows a QR, the phone scans and confirms, then the phone
  advertises the custom service and the Mac auto-connects. There is no
  pairable-device picker.
- Core Bluetooth advertisement dictionaries must use `CBUUID`, not Foundation
  `UUID`. Passing `UUID` makes advertising fail or omit the service, so a Mac
  scanning for the custom service never sees the phone.
- The Mac companion hosts a loopback-only debug HTTP server on
  `127.0.0.1:18765` (`GET /state`, `GET /health`). It writes
  `/tmp/phoneremote-mac-debug.json`. Use `./scripts/debug-mac.sh`. The payload
  has pairing/BLE status and display names only; never QR text, keys, or
  device identifiers. Set `PHONE_REMOTE_DEBUG_SERVER=0` to disable.
- Guard `stopScan`, `stopAdvertising`, and `removeAllServices` on `.poweredOn`.
  Calling them during manager init logs `API MISUSE` and can confuse later
  state. After an unpaired connect/discovery failure, the Mac must resume
  scanning; staying in `disconnected` hides a later advertising phone.
- Physical install signing is opt-in: `install-phone.sh` requires
  `PHONE_REMOTE_SIGNING=1` plus a local `PHONE_REMOTE_DEVELOPMENT_TEAM` and
  never stores those values. Build-only probes remain signing-disabled.
- For a physical signed build, pass the phone as the explicit Xcode
  destination (`platform=iOS,id=<local-only>`). A generic device build can
  produce a valid profile for a different paired phone and then fail at
  install; the repeatable install script now selects the supplied destination.
- Embedded shared frameworks must use an `@rpath/...` install name, and the
  application executable/debug dylib must include `@executable_path/Frameworks`
  in `LD_RUNPATH_SEARCH_PATHS`. `devicectl` can report a successful launch
  request even when the process immediately dies; use `--console` or a delayed
  process query to catch dynamic-loader failures.

## Swift 6 and framework boundaries

- Static collections of protocol/GATT value types must use `Sendable` value
  types under complete concurrency checking. Add conformances only to immutable
  enums/structs; do not paper over mutable state with `@unchecked Sendable`.
- Imported ApplicationServices globals such as the AX prompt key can trigger
  strict-concurrency diagnostics. A literal CFDictionary key avoids capturing
  a mutable imported global while keeping the permission request
  Accessibility-only.
- Keep shared files transport-neutral. Core Bluetooth, Core Graphics, Core
  Motion, AVFoundation, and Speech types belong in app adapters; shared code
  exchanges `Data`, UUIDs, fixed-width values, and protocol-owned enums.
- The generated app module names are `PhoneRemote_iOS` and
  `PhoneRemote_macOS`; XCTest imports must match those names exactly.

## Protocol, BLE, and pairing invariants

- The v1 protocol envelope is capped at 8,192 bytes; bounded byte fields are
  capped at 2,048 bytes. Validate declared array counts before reserving or
  allocating storage.
- BLE framing uses a 16-byte header and must work at the 20-byte ATT-safe
  minimum. Keep data and control characteristics separate, bound queues and
  reassembly, and clear all partial/retry state on disconnect.
- BLE readiness (service discovery, characteristic validation, notifications)
  is not authenticated-session readiness. Feature traffic must wait for the
  X25519/HKDF/AEAD handshake to complete.
- Pairing QR text is canonical bounded binary with unpadded Base64URL and a
  `prqr1.` tag. Tokens are one-active, single-use, and expire no later than
  120 seconds. Inject a clock into both the token store and its UI controller
  so expiry tests are deterministic.
- Reject all-zero key/secret material, modified transcripts/ciphertexts, wrong
  peer identities, replayed envelopes, and sequence rollback. Trusted
  reconnects use fresh ephemeral keys and a new authenticated session; a BLE
  identifier or display name is never sufficient.
- Never put payload bytes, QR material, keys, text, transcripts, or audio in
  metrics/logs. Metrics should record only message types, counts, sizes,
  sequence outcomes, timing buckets, and lifecycle states.

## Safety and feature boundaries

- Input policy is fail-closed: authentication, active state, unlocked/awake
  Mac, logged-in user, and explicit Accessibility `.granted` are all required.
  Unknown Accessibility state is not controllable.
- Every unsafe transition, disconnect, watchdog expiry, pause, startup, and
  termination funnels through one idempotent `releaseAllInputs` path. The
  watchdog is 500 ms and reliable actions have finite retry attempts.
- Keep the Mac command allowlist explicit. The shared protocol represents
  hotkeys atomically; long-held modifier messages are intentionally not added
  until disconnect fault testing proves safe.
- Trackpad zero-distance samples should not emit zero pointer/scroll packets.
  A bounded tap travel threshold prevents a meaningful pointer movement from
  becoming a click; the current default is six logical points.
- Push-to-talk activation is local-only. Backgrounding, interruption, route
  changes, cancellation, or permission loss stop capture and reset chunking.
  Audio chunks are 16 kHz mono signed 16-bit PCM with explicit sequence/sample
  metadata; Mac reassembly measures gaps/duplicates rather than hiding them.
- Transcript insertion is an explicit local action routed back through the
  existing safe text-input path; receiving a transcript never injects text by
  itself.

## Testing and hardware evidence

- The fastest deterministic check is `PhoneRemoteSharedTests`; it exercises
  protocol, framing, transport, observability, pairing, and encrypted
  envelope/framing integration without Apple hardware.
- Current automated evidence is 24 shared tests, 19 macOS tests, and 17 iOS
  simulator tests, all passing. These prove code paths, not radio performance
  or real input/audio behavior.
- macOS XCTest may print `com.apple.linkd.autoShortcut` service warnings in
  the host environment while still passing; distinguish those warnings from
  actual test failures.
- The macOS app can be smoke-launched from a built `.app` with `open -n`; the
  read-only `scripts/logs-mac.sh` probe then exits 0. Unified-log output may
  include unrelated CoreSpotlight/XPC noise, so filter by the Phone Remote
  process and do not treat those notices as product failures automatically.
- After the owner enabled Developer Mode and restarted, the latest read-only
  probe sees the target physical iPhone as `available (paired)`. A second
  physical phone is unavailable. USB visibility is not install/launch
  evidence.
  Signed install and launch are now verified; Gate A remains blocked only by
  iPhone diagnostics tooling, while Gates B–F remain `NOT RUN` pending camera,
  Accessibility, Bluetooth, motion, microphone, and Speech runs.
- A bounded unsigned `install-phone.sh` probe separates source/build readiness
  from device readiness: the physical SDK build passed, while
  `devicectl device install app` failed to mount the DDI (CoreDevice 12040)
  because the phone was locked. Unlock the phone and configure local signing
  before retrying installation; Developer Mode has now been enabled by the
  owner.
- `devicectl list devices` becoming `available (paired)` and `device info
  details` reporting Developer Mode Enabled still do not prove DDI readiness.
  Check `device info ddiServices` while the phone remains unlocked on-screen;
  a phone that has only been unlocked once since boot can still return
  CoreDevice 12040 with a locked-device recovery reason.
- A real-device install also needs a local Apple development certificate/team.
  `security find-identity -v -p codesigning` is the quickest local check; use
  Xcode Accounts to create/select the identity and do not manufacture or
  commit signing material.
- On this Xcode 27/device-support combination, `devicectl device sysdiagnose`
  and `scripts/logs-phone.sh` can fail with the generic
  `CoreDeviceCLISupport.DiagnoseError error 0` even when DDI, install, and
  launch work. Preserve that as a tooling blocker and do not treat an empty
  archive as app-log evidence.
- Do not mark a ticket complete from a compile alone. Record command, target,
  OS/device class, test count, and any hardware limitation in
  `docs/implementation_progress.md`; keep the TODO checkbox unchecked until
  its acceptance criteria and required evidence are actually met.

## Pairing UI and first-session bridge

- A SwiftUI `UIViewRepresentable` that hosts an
  `AVCaptureVideoPreviewLayer` can be created before SwiftUI assigns its final
  size. Put the layer in a small UIKit view and set `previewLayer.frame =
  bounds` in `layoutSubviews`; this makes the physical QR camera feed visible
  instead of relying on the initial `.zero` frame.
- The first-pairing runtime path is now: scanner confirmation → foreground
  peripheral advertising → BLE service/characteristic readiness → framed
  control `PairingClientHello` → Mac one-time offer consumption and server hello
  → client finish → trust-record write → paired UI. Keep “BLE ready” visibly
  distinct from “paired”; discovery or a connected UUID is not authentication.
- The QR secret and Mac ephemeral private key stay local to the Mac. The phone's
  hello carries only the pairing ID and public handshake material; the Mac
  consumes the active offer atomically by pairing ID, and no trust record is
  written until the authenticated finish succeeds.
- A local motion sink that only records deltas is not the production path.
  Core Motion callbacks arrive off the main actor; hop to `@MainActor` before
  wrapping and sending BLE frames, and map `motionPointerDelta` onto the Mac
  pointer injector instead of adding a second mouse path.
- Use the QR pairing ID as the shared first trust-record device ID on both sides.
  It avoids treating a Core Bluetooth identifier or display name as identity,
  Trusted reconnect reuses that pairing ID plus the persisted identity keys, with a fresh ephemeral handshake and no QR.
- The Mac progress model is deliberately presentation-only (`scanning`,
  `connecting`, `authenticating`, `paired`, etc.). Keep central transport state
  and authenticated session state separate so a transient disconnect cannot
  leave a false paired indicator.
- On macOS, `SecItemCopyMatching` rejects a generic-password query that combines
  `kSecMatchLimitAll` with `kSecReturnData` (`errSecParam`). To list per-device
  records, request `kSecReturnAttributes` with the all-items limit, extract and
  validate each account UUID, then fetch each value with a single-record data
  query. Treat an attribute without a decodable value as inconsistent state and
  fail closed; do not silently fall back to an unprotected store.
- If `xcodebuild` reports no account/profile from a non-GUI CLI session while a
  local development certificate and a previously device-valid profile are
  available, a bounded local diagnostic can sign the freshly built app in
  place, verify it deeply, and install it with `devicectl`. Treat this only as
  a recovery probe: keep the normal `install-phone.sh` automatic-signing path
  documented, never copy signing values into the repo, and do not infer feature
  success from install/launch liveness.
