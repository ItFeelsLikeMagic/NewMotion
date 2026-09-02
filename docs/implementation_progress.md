# Implementation Progress and Handoff Log

This is an append-only checkpoint log for the iPhone BLE Remote MVP. Update it after each meaningful implementation or verification event so work can resume after a crash or context loss.

## How to use this log

- Add a dated entry; do not rewrite earlier evidence.
- Name the exact ticket IDs, files/commits (when available), commands, results, and next action.
- Distinguish `implemented`, `verified`, `blocked`, and `not run`.
- Never include secrets, device identifiers, typed text, transcripts, QR payloads, keys, or audio content.
- The TODO backlog remains the authoritative checklist; a ticket checkbox is checked only after root verifies its acceptance criteria.

## Checkpoints

### 2026-09-02 — initial implementation dispatch

- **State:** `in progress`
- **Repository:** Git initialized on `main`; source scope and ticket backlog are under `docs/`.
- **Dispatched:** Foundation/shared stream (`FND-001–003`, `PRO-001–002`, `SIM-001`, `OBS-001`); BLE/pairing stream (`BLE-001–005`, `PAIR-001–005`); safety/features stream (`SAFE-001–004`, `PAD-001–002`, `KEY-001–002`, `MOT-001–002`, `AUD-001–003`, `LIFE-001`).
- **Root ownership:** Shared-file reconciliation, integration tests, simulator tests, physical-device smoke checks, `QA-001`, and `QA-002`.
- **Known environment evidence:** Xcode 27.0 is installed; `xcodegen` was not present on the PATH at dispatch. The foundation stream must provide or document a reproducible project-generation fallback.
- **Next action:** Wait for worker checkpoints, inspect their diffs, run focused tests, then integrate in dependency order.

### 2026-09-02 — host/device capability probe

- **State:** `verified environment; implementation in progress`
- **Host:** Apple silicon MacBook Pro (M1 Max); Xcode 27.0 (`27A5252f`) is installed.
- **Project tooling:** `xcodegen` is not currently on `PATH`; project generation must use a documented fallback or be installed later.
- **Simulator:** `xcrun simctl list devices available` currently reports no available iOS simulator devices.
- **Physical phone:** `xcrun devicectl list devices` sees an iPhone 15 Pro Max (`iPhone16,2`) as `connected (no DDI)`. This is evidence of USB visibility only, not install/launch readiness; trust, Developer Mode, and a matching DDI may still be required.
- **Next action:** Do not claim Gate A physical install success until a generated app is installed/launched and logs are collected on the phone.

### 2026-09-02 — BLE/pairing worker checkpoint 1

- **State:** `implemented pieces; integration pending`
- **Present:** `docs/ble_gatt_contract.md`, `Shared/Crypto/PairingTypes.swift`, `Shared/Crypto/PairingHandshake.swift`, and BLE framing implementation are being added by the BLE/pairing stream.
- **Evidence:** `swiftc -parse-as-library -typecheck Shared/Crypto/*.swift` passed for the current crypto files.
- **Integration assumptions:** Shared protocol envelopes remain at or below 8,192 bytes; `Shared/Crypto` must be included in both app and test targets; BLE adapters exchange `Data` and UUIDs rather than framework types in shared code.
- **Still pending:** Core Bluetooth iPhone/Mac shells, QR scanner/offer UI, pairing attack tests, integration with the generated project, and hardware Gate B/C evidence.
- **Next action:** Root will type-check the stream after the worker finishes and reconcile target membership before checking any PAIR/BLE tickets.

### 2026-09-02 — first generated-project build probe

- **State:** `blocked on script invocation; not a product failure`
- **Evidence:** The fallback generator produced `PhoneRemote.xcodeproj` and `xcodebuild -list` enumerated six expected targets/schemes.
- **Failure:** `./scripts/build.sh` stops at the first iOS build because Xcode 27 rejects `-target` combined with `-derivedDataPath` unless `-scheme`, `-testProductsPath`, or `-xctestrun` is also supplied.
- **Action:** Foundation worker has been asked to make the build script scheme-based or otherwise valid for Xcode 27. No build/test ticket is checked from this probe.

### 2026-09-02 — direct scheme build probe

- **State:** `blocked on fallback project source paths; not a product failure`
- **Evidence:** `xcodebuild -list -project PhoneRemote.xcodeproj` succeeds and lists all six targets/schemes.
- **Failure:** A direct `PhoneRemote-iOS` scheme build reaches Swift compilation but the generated `PhoneRemoteShared.SwiftFileList` contains duplicated paths such as `Shared/Shared/Protocol/ProtocolTypes.swift`; the files are present at `Shared/Protocol/...`.
- **Action:** Foundation worker has been asked to fix `scripts/generate_fallback.py` path handling and regenerate. This supersedes the earlier script-invocation blocker for the next build attempt.

### 2026-09-02 — shared target reached Swift 6 compilation

- **State:** `blocked on strict-concurrency annotations; not a runtime failure`
- **Evidence:** After fallback path fixes, a direct iOS scheme build reaches `Shared/Crypto` compilation and includes the crypto/framing sources.
- **Failure:** Swift 6 strict-concurrency diagnostics reject non-`Sendable` value types used in static constants (`BLEFrameFlags`, `BLEFramingLimits`, `BLECharacteristicProperties`, and GATT definition collections).
- **Action:** BLE/pairing worker has been asked to add justified `Sendable` conformances and rerun the scheme build. This is a compile integration issue, not evidence that BLE or pairing behavior passes.

### 2026-09-02 — app/framework module-boundary checkpoint

- **State:** `implemented; awaiting full build`
- **Change:** BLE/pairing stream added conditional `import PhoneRemoteShared` to iPhone/Mac BLE and pairing consumers so app targets can resolve shared crypto/protocol types through the framework.
- **Remaining integration checks:** Confirm `project.yml` and fallback target membership include all Shared/Crypto sources; align the shared framework deployment target with iOS 18/macOS 15; then rerun both app builds and test bundles.

### 2026-09-02 — BLE/pairing implementation checkpoint 2

- **State:** `implemented pieces; verification pending`
- **Change:** BLE/pairing stream now includes Core Bluetooth shells/adapters, bounded framing/scheduler, QR offer/scanner/coordinators, X25519/HKDF session wrappers, trust remember/list/revoke, and verification templates for Gates B/C.
- **Evidence:** Worker reports strict Swift 6 type-check passed for Shared/Crypto plus iPhone/Mac BLE and pairing sources; root has not yet accepted that as target build evidence.
- **Security hardening:** Token validation rejects all-zero key/secret material; trusted reconnect uses a fresh authenticated handshake.
- **Still pending:** Full generated-project build/test, adversarial executable tests, and physical BLE/QR measurements. Gate B/C templates intentionally remain `not run` until hardware is ready.

### 2026-09-02 — strict concurrency follow-up

- **State:** `blocked on platform annotation; not a runtime failure`
- **Evidence:** Root strict type-check found `kAXTrustedCheckOptionPrompt` in ApplicationServices is a non-concurrency-safe imported global under Swift 6.
- **Action:** Safety worker has been asked to isolate or replace that reference while keeping the permission request Accessibility-only. No SAFE ticket is checked from this diagnostic.

### 2026-09-02 — first complete build matrix

- **State:** `verified build; test execution in progress`
- **Command:** `./scripts/build.sh` (Xcode 27.0, generated fallback project, signing disabled).
- **Evidence:** iOS app, macOS app, shared test bundle, iOS test bundle, and macOS test bundle each returned `** BUILD SUCCEEDED **`.
- **Integration fixes:** Added `CryptoKit` to `Tests/Shared/TransportPairingTests.swift`; aligned iOS test imports to `PhoneRemote_iOS`; enabled testability on app targets; added app `TEST_HOST`/`BUNDLE_LOADER` settings for iOS/macOS XCTest linking in `project.yml` and `scripts/generate_fallback.py`.
- **Still pending:** Execute XCTest suites, cross-feature end-to-end checks, simulator install/launch/log capture, and physical iPhone readiness.

### 2026-09-02 — shared XCTest suite

- **State:** `verified`
- **Command:** `xcodebuild test -project PhoneRemote.xcodeproj -scheme PhoneRemoteSharedTests -destination 'platform=macOS' ...`.
- **Evidence:** 21 shared tests executed with 0 failures, including protocol, simulated transport, observability, BLE framing, and pairing-store coverage.
- **Next action:** Fix the injected-clock pairing test defect and update the pause-transition expectation, then rerun the macOS suite.

### 2026-09-02 — macOS XCTest suite

- **State:** `verified`
- **Command:** `xcodebuild test -project PhoneRemote.xcodeproj -scheme PhoneRemote-macOSTests -destination 'platform=macOS,arch=arm64' ...`.
- **Evidence:** 12 macOS tests executed with 0 failures (app metadata, BLE central state machine, QR expiry/cancellation, input safety, watchdog/retry, audio reassembly, transcript gating, lifecycle guards).
- **Observed environment noise:** Xcode emitted `com.apple.linkd.autoShortcut` service warnings while launching the test host; tests still passed and no product error was reported.

### 2026-09-02 — first iOS simulator execution after packaging repair

- **State:** `blocked on test fixtures/gesture semantics; simulator launch now works`
- **Command:** `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteScriptedTests ./scripts/test.sh` with an automatically selected iPhone 17 Pro simulator (iOS 27.0).
- **Evidence:** The app and test bundle installed/launched; 9 iOS tests ran. Three failures are now ordinary executable assertions: a pairing fixture exceeded the 120-second token lifetime by one second, a zero-distance move emitted a zero pointer packet, and a 10-point move was still classified as a tap under the current default threshold.
- **Action:** Safety/BLE workers are correcting the fixture and gesture behavior; root will rerun the full scripted suite. The prior `MissingBundleExecutable` packaging blocker was fixed by adding `CFBundleExecutable=$(EXECUTABLE_NAME)` to both app plists.

### 2026-09-02 — scripted shared/macOS/iOS verification

- **State:** `verified automated test loop`
- **Command:** `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteScriptedTestsFinal ./scripts/test.sh`.
- **Evidence:** Shared suite 21/21 passed; macOS suite 12/12 passed; iOS simulator suite 9/9 passed on iPhone 17 Pro simulator, iOS 27.0. The script selected the simulator by UUID from `simctl` rather than relying on a fixed device name.
- **Behavior fixes:** Trackpad now suppresses zero deltas and uses a bounded 6-point tap travel threshold; iOS pairing fixture and timestamp assertion account for canonical millisecond encoding.
- **Still pending:** Physical iPhone install/launch/log loop, BLE soak/latency, QR scan, input/manual feature checks, and Gates B–F hardware evidence.

### 2026-09-02 — cross-layer integration verification

- **State:** `verified automated integration`
- **Changes:** Added a shared protocol → ChaChaPoly session → BLE fragment/reassembly → protocol decode test; an iOS trackpad/audio → shared payload → envelope/framing test; and a macOS framed input → shared command bridge → safety injector/mock sink/release test.
- **Command:** `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteScriptedTestsIntegration ./scripts/test.sh`.
- **Evidence:** Shared 22/22, macOS 14/14, and iOS simulator 11/11 tests passed. The test script selected the iPhone 17 Pro simulator (iOS 27.0) automatically.
- **Still pending:** Hardware-only BLE throughput/latency, QR camera confirmation, real Accessibility event posting, motion target selection, five-minute audio/transcription, lifecycle fault matrix, and final go/no-go.

### 2026-09-02 — app surfaces, signing guard, and bounded fuzz checkpoint

- **State:** `implemented; automated verification pending rerun`
- **App changes:** Replaced the placeholder app views with a Mac menu-bar
  status/pause/accessibility surface and an iPhone trackpad/air-mouse/push-to-
  talk control surface. The iPhone feature model keeps motion/audio local and
  drops output until authenticated transport is connected.
- **Device workflow:** `install-phone.sh` now supports opt-in local signing via
  `PHONE_REMOTE_SIGNING=1` and `PHONE_REMOTE_DEVELOPMENT_TEAM`; missing values
  fail before any device command. No signing values are committed.
- **Protocol hardening:** Added a deterministic 2,000-input decoder corpus and
  `scripts/fuzz-protocol.sh`; the focused run passed (1 test, 0 failures).
- **Hardware probe:** A fresh read-only `devicectl list devices` check reports
  physical iPhones as unavailable. Simulator runtimes are available; no
  physical install/launch/log evidence is claimed.
- **Documentation:** Added Gate D/E/F templates and the conservative
  [`go-no-go.md`](verification/go-no-go.md); Gate A/C notes now reflect the
  latest automated counts and physical boundary.
- **Next action:** Rerun full build, strict Swift 6 type-check, fuzz, and the
  scripted shared/macOS/iOS suites, then reconcile TODO ticket checkboxes.

### 2026-09-02 — app/pairing UI and final scripted test pass

- **State:** `verified automated baseline; hardware gates remain blocked`
- **UI integration:** Mac now renders the one-time QR offer with expiry and
  cancellation controls beside live safety/accessibility status. iPhone now
  presents a camera preview, one confirmation/cancel path, trackpad and
  clutch controls, and local push-to-talk permission/capture controls.
- **BLE coverage:** Added iPhone peripheral adapter tests for foreground and
  powered-on advertising gates, required subscriptions, bounded queues, and
  disconnect cleanup.
- **Command:** `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalScriptedTests ./scripts/test.sh`.
- **Evidence:** Shared 23/23, macOS 14/14, and iOS simulator 14/14 tests
  passed. The deterministic decoder corpus (2,000 inputs) also passed. The
  known macOS `com.apple.linkd.autoShortcut` service messages and simulator
  Core Motion preference notice were environment noise; no test failed.
- **Still pending:** Physical install/signing/trust/Developer Mode, BLE soak,
  QR camera run, real Accessibility injection, motion calibration, five-minute
  audio/transcription, lifecycle fault matrix, and Gate A–F go/no-go.

### 2026-09-02 — final automated verification checkpoint

- **State:** `verified automated; physical gates blocked`
- **Build:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalBuild ./scripts/build.sh` exited 0; iOS app, macOS app, shared tests, iOS tests, and macOS tests each reported `BUILD SUCCEEDED`.
- **Tests:** `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalScriptedTests ./scripts/test.sh` exited 0 with shared 23/23, macOS 14/14, and iOS simulator 14/14 tests passing.
- **Strict check:** The repository's Swift 6 complete-concurrency pure-source type-check exited 0.
- **Fuzz:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteProtocolFuzz ./scripts/fuzz-protocol.sh` exited 0; the deterministic 2,000-input decoder corpus passed.
- **Packaging:** Fresh simulator and macOS app plists contain the expected executable names; no `MissingBundleExecutable` failure remains.
- **Physical boundary:** The latest `devicectl` probe sees the target phone as paired but `connected (no DDI)`; `device info details` reports Developer Mode Disabled, and a second phone is unavailable. No install, launch, sysdiagnose, BLE soak, camera, Accessibility, motion, audio, or Speech result is claimed.
- **Next action:** Enable the documented GUI prerequisites and run the bounded Gate A–F procedures before changing scope or marking hardware-dependent tickets complete.

### 2026-09-02 — BLE lifecycle wiring and privacy metadata checkpoint

- **State:** `implemented; automated verification passed after one packaging fix`
- **Runtime wiring:** The iPhone model now owns the Core Bluetooth peripheral
  transport and starts foreground advertising only after scanner confirmation;
  background/inactive transitions stop it. The Mac model starts the
  service-filtered central scan and keeps BLE-ready separate from authenticated
  input status.
- **Privacy metadata:** Added Bluetooth, camera, and motion usage descriptions
  to the appropriate app plists. A first macOS host launch failed closed on a
  missing Bluetooth usage string; adding it restored the test host.
- **Motion coverage:** Added stationary-noise, acceleration, gap-reset, and
  extreme-rotation assertions to the iOS filter suite.
- **Verification:** The rerun exited 0 with shared 23/23, macOS 14/14, and iOS
  simulator 15/15. The five-target build and strict Swift 6 check remain
  green; only known Xcode service/simulator notices appear.
- **Still pending:** Physical phone availability/signing/Developer Mode,
  BLE soak and QR scan, Accessibility event posting, calibrated air mouse,
  five-minute audio/transcription, lifecycle fault matrix, and final go/no-go.

### 2026-09-02 — final verification reconciliation

- **State:** `automated baseline reverified; physical gates remain blocked`
- **Build:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalBuild3 ./scripts/build.sh` exited 0. The iOS app, macOS app, shared test bundle, iOS test bundle, and macOS test bundle each reported `BUILD SUCCEEDED`.
- **Strict check:** The pure-source Swift 6 complete-concurrency type-check exited 0 with no diagnostics (`/tmp/phone_remote_strict_final2.log`).
- **Tests:** `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalTests3 ./scripts/test.sh` remains green: shared 23/23, macOS 14/14, and iOS simulator 15/15. `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalFuzz3 ./scripts/fuzz-protocol.sh` also exited 0; the deterministic 2,000-input protocol corpus passed.
- **Project/static checks:** `xcodebuild -project PhoneRemote.xcodeproj -list` lists all six expected targets/schemes; no Swift source still contains the placeholder `Foundation scaffold` marker.
- **Warnings:** Xcode AppIntents metadata and macOS `com.apple.linkd.autoShortcut` service messages remain non-failing environment notices.
- **Physical boundary:** The latest read-only `devicectl` probe sees the target phone as paired but `connected (no DDI)` with Developer Mode Disabled; a second physical phone is unavailable. No physical install, BLE soak, QR camera scan, Accessibility event-posting, motion calibration, audio/Speech, or lifecycle-fault result is claimed.
- **Next action:** When the owner enables Developer Mode, trust, signing, and device availability, run the bounded Gate A–F procedures and update the TODO checkboxes only with their measured evidence.

### 2026-09-02 — bounded physical install probe

- **State:** `physical install blocked by device prerequisites`
- **Probe:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePhysicalProbe IPHONE_UDID=<local-only> ./scripts/install-phone.sh` used the default signing-disabled mode. The iOS device build completed successfully, so source compilation for the physical SDK is verified.
- **Observed failure:** `devicectl device install app` exited 1 because the developer disk image could not be mounted (CoreDevice error 12040); the reported recovery reason was that the device was locked. A separate `device info details` probe reports Developer Mode Disabled.
- **Privacy:** The device identifier was used only through a local environment variable and is not recorded here.
- **Still pending:** Unlock the phone, enable Developer Mode and confirm its reboot, configure local signing/team values, then rerun install/launch/log collection before claiming Gate A or any physical feature gate.

### 2026-09-02 — Developer Mode restart recheck

- **State:** `device available; install still blocked by local prerequisites`
- **Probe:** After the owner enabled Developer Mode and restarted, `xcrun devicectl list devices` reports the target iPhone as `available (paired)`.
- **Install attempt:** The signing-disabled physical-SDK build passed again, but `devicectl device install app` exited 1 while mounting the DDI because the phone was locked (CoreDevice error 12040 / device-locked recovery reason).
- **Signing boundary:** `security find-identity -v -p codesigning` reports zero valid identities on this Mac. No signed install, launch, log collection, or physical feature gate can be claimed yet.
- **Next action:** Unlock the phone, verify the Developer Mode reboot is complete, sign into Xcode/select a development team locally, then rerun `install-phone.sh` with `PHONE_REMOTE_SIGNING=1` and the team value kept only in the local environment.

### 2026-09-02 — Developer Mode confirmed; DDI and signing remain

- **State:** `device paired and Developer Mode enabled; physical install blocked`
- **Device evidence:** `xcrun devicectl device info details` now completes and reports Developer Mode Enabled, iOS 27.0, and a booted paired target. `xcrun devicectl list devices` reports the target as available/paired or connected without DDI depending on the service query.
- **DDI evidence:** `devicectl device info ddiServices` still exits 1 with CoreDevice error 12040 and the recovery reason that the device is locked. The lock-state query reports `unlockedSinceBoot=true`, which is not sufficient to establish that the phone is currently unlocked for DDI services.
- **Signing evidence:** `security find-identity -v -p codesigning` reports zero valid identities on this Mac; no signed app install is possible until a local Apple development identity/team is configured.
- **Next action for owner:** Keep the phone unlocked on-screen and connected, sign into Xcode/select a development team (without committing signing values), then tell the worker to rerun the DDI check and signed install/launch/log loop.

### 2026-09-02 — physical service and unsigned install recheck

- **State:** `Developer Mode and DDI verified; signed install blocked by certificate`
- **Device evidence:** The target is paired and Developer Mode Enabled; `device info ddiServices` reports compatible content with `isUsable: true`.
- **Install evidence:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePhysicalUnsignedReady IPHONE_UDID=<local-only> ./scripts/install-phone.sh` rebuilt the physical-SDK app successfully, then `devicectl device install app` exited 1 with CoreDevice 3002 / MIInstaller 13 (`No code signature found`).
- **Signing evidence:** `security find-identity -v -p codesigning` still reports zero valid identities on this Mac.
- **Next action:** Create/select an Apple Development certificate in Xcode Accounts for the signed-in team, then rerun the signed install/launch/log loop while keeping the phone unlocked.

### 2026-09-02 — signed provisioning and target-specific install

- **State:** `signed install verified; launch packaging issue found and being fixed`
- **Provisioning:** The owner signed into Xcode. A local Apple Development identity became available, and a physical-SDK build targeted explicitly at the supplied phone completed with automatic provisioning enabled. The embedded profile was checked locally to contain that target; no team ID, UDID, or profile contents are recorded.
- **Install:** `install-phone.sh` in opt-in signed mode (`PHONE_REMOTE_SIGNING=1` with local-only team/UDID environment) exited 0 and installed bundle ID `com.example.phoneremote.ios`.
- **Launch probe:** The first launch request returned 0 but the app terminated because the shared framework had an absolute install name. Changing it to `@rpath/PhoneRemoteShared.framework/PhoneRemoteShared` removed the first loader failure.
- **Next action:** Add the embedded-framework runpath to both app targets, rebuild, reinstall, and verify a delayed process query rather than trusting only the launch request.

### 2026-09-02 — physical launch survives runpath fix

- **State:** `signed install and launch verified; device diagnostics blocked`
- **Packaging fix:** `project.yml` and `scripts/generate_fallback.py` now set `LD_RUNPATH_SEARCH_PATHS` to include `@executable_path/Frameworks` for iOS and the corresponding embedded-framework paths for macOS. The signed iOS app's debug dylib and executable show the expected runpaths; `codesign --verify --deep --strict` exits 0.
- **Install/launch:** A fresh target-specific signed build and `devicectl device install app` both exited 0. `launch-phone.sh` exited 0, and `devicectl device info processes` three seconds later showed the Phone Remote app process still present. A bounded `--console` launch produced no `dyld` error before the probe was stopped.
- **Regression:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalBuildAfterRunpath ./scripts/build.sh` exited 0. `PHONE_REMOTE_RUN_IOS_TESTS=1 PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalTestsAfterRunpath ./scripts/test.sh` exited 0 with shared 23/23, macOS 14/14, and iOS simulator 15/15.
- **Next action:** Run the interactive Mac/iPhone pairing and feature gate procedures. Do not mark Gates B–F or hardware-dependent tickets complete from process liveness alone.

### 2026-09-02 — iPhone diagnostic collection retry

- **State:** `blocked by Xcode diagnostic tooling; app remains launched`
- **Probe:** With the paired phone unlocked and the signed app running, `IPHONE_UDID=<local-only> PHONE_REMOTE_PHONE_LOG_OUTPUT=/tmp/PhoneRemotePhysicalLogsRunpath ./scripts/logs-phone.sh` exited 1.
- **Observed failure:** Xcode 27 returned `CoreDeviceCLISupport.DiagnoseError error 0` and emitted only Apple's standard diagnostic privacy notice; no sysdiagnose archive was produced. This is not evidence of an app crash because the delayed process query still found the app.
- **Next action:** Retry on a compatible/newer Xcode device-support bundle or capture a redacted equivalent console aggregate. Keep Gate A blocked for complete log collection while signed install/launch remain passing.

### 2026-09-02 — current handoff boundary

- **Automated:** Build, strict Swift 6 complete-concurrency type-check, scripted shared/macOS/iOS suites (23/23, 14/14, 15/15), and deterministic 2,000-input protocol corpus remain green.
- **Physical:** Paired iPhone 15 Pro Max on iOS 27.0 with Developer Mode and usable DDI; signed install and launch pass. No physical BLE soak, QR/camera pairing, Accessibility injection, motion calibration, microphone/Speech run, or lifecycle fault matrix has been run.
- **Latest device check:** `device info ddiServices` exits 0 with `contentIsCompatible=true` and `isUsable=true` while the phone is kept unlocked; no device identifiers are recorded.
- **Documentation:** TODO and Gate A/go-no-go records now distinguish the passing install/launch subchecks from the blocked diagnostics and unrun feature gates. No commit has been created.

### 2026-09-02 — macOS CLI launch/log probe

- **State:** `macOS launch/log subcheck verified`
- **Probe:** `open -n` launched the freshly built `PhoneRemoteMac.app`; the
  read-only `PHONE_REMOTE_LOG_WINDOW=1m ./scripts/logs-mac.sh` command exited 0
  and returned process-scoped unified-log output. The host emitted unrelated
  CoreSpotlight/XPC noise, but no Phone Remote crash was observed.
- **Boundary:** FND-003 still remains unchecked because the iPhone log command
  is blocked by Xcode's generic diagnostic error, even though the Mac
  launch/log subcheck and signed iPhone install/launch subchecks pass.

### 2026-09-02 — camera preview and authenticated pairing bridge

- **State:** `implemented; automated verification passed; physical rerun pending`
- **Camera fix:** The iPhone QR preview now owns its
  `AVCaptureVideoPreviewLayer` inside a layout-aware `UIView` and reapplies the
  bounds during `layoutSubviews`, preventing SwiftUI's initial zero-sized
  layout from hiding the live camera feed.
- **Pairing bridge:** The confirmed QR token now drives the existing BLE
  lifecycle into a framed control-channel hello/server-hello/finish exchange.
  The Mac consumes the one-time offer by pairing ID, writes the authenticated
  phone trust record only after the finish message, and retains the stable
  paired-device summary for the menu-bar UI. BLE-ready and authenticated/paired
  are intentionally separate states.
- **Mac UI:** The menu-bar surface now reports scanning, connecting,
  authenticating, paired, disconnected, and failed states and displays the
  last paired phone name after successful trust persistence.
- **Verification:** `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePairingUIBuild3
  ./scripts/build.sh` exited 0. `PHONE_REMOTE_RUN_IOS_TESTS=1
  PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePairingUITests3 ./scripts/test.sh`
  exited 0 with shared 24/24, macOS 16/16, and iOS simulator 15/15. The added
  coverage includes one-time offer consumption, the Mac coordinator bridge,
  visible BLE device snapshots, and progress-state labels.
- **Still pending:** Reinstall the signed build on the physical iPhone and run
  the QR camera/confirmation flow to capture the live preview and Mac paired
  device transition. Do not mark the hardware QR/trust gate complete until that
  interaction is observed.

### 2026-09-02 — refreshed physical build installed

- **State:** `signed install/launch verified; interactive pairing pending`
- **Build/install:** The normal signed script could not resolve the Xcode
  account/profile from this CLI session even though the local Apple Development
  certificate is present. For this bounded local probe, the freshly built
  physical-SDK app was signed in place with that certificate and the existing
  device-valid development profile, then passed `codesign --verify --deep
  --strict` and `devicectl device install app`.
- **Launch:** `devicectl device process launch --terminate-existing` exited 0;
  a delayed process query still found the Phone Remote process on the paired
  iPhone. This proves the refreshed camera/pairing code is installed and
  running, but not that the camera preview or BLE handshake has completed.
- **Next action:** Use the Mac menu-bar QR action and the iPhone scanner to
  observe the live preview, confirm the offer, and verify the Mac changes to
  `Paired with <phone>` with a paired-device row. Record only the visible
  states; never capture or log the QR payload.

### 2026-09-02 — macOS Keychain enumeration fix

- **State:** `storage initialization fixed; interactive pairing rerun pending`
- **Root cause:** `KeychainTrustedDeviceStore.allRecords()` requested record
  data together with `kSecMatchLimitAll`. macOS returns `errSecParam` for that
  combination, so `MacPairingCoordinator` initialization threw and the menu-bar
  model showed its generic “Pairing storage is unavailable” fallback before a
  QR offer could be created.
- **Fix:** Enumerate matching Keychain account attributes first, then fetch each
  record through the existing single-record/decode path. Inconsistent entries
  now fail closed instead of being silently omitted.
- **Verification:** The isolated macOS Keychain regression test saves and lists
  a record successfully; the normal macOS suite passes 18/18, and
  `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePairingStorageFixBuild
  ./scripts/build.sh` exits 0. The rebuilt app was launched with `open -n`;
  Computer Use could not obtain a menu-bar accessibility snapshot, so the
  actual QR click and physical phone flow still require an owner-visible rerun.
- **Next action:** Relaunch the rebuilt Mac app, choose “Show one-time pairing
  QR,” and repeat the camera/confirm flow. The expected pre-pairing state is a
  QR offer (not a storage error); only the authenticated finish should create
  the paired-device row.

### 2026-09-02 — BLE discovery is in-app only

- **State:** `code/tests verified; physical QR confirm still pending`
- **Owner report:** The iPhone does not show as pairable in macOS Bluetooth
  Settings. That is the intended v1 path. The Mac companion also has no
  pairable-device list; it scans for the custom GATT service and connects
  after the phone confirms the QR.
- **Bugs found:** iPhone advertising passed a Foundation `UUID` in
  `CBAdvertisementDataServiceUUIDsKey`, so Core Bluetooth could not advertise
  the service the Mac scans for. Unpaired Mac connect/discovery failures
  stayed in `disconnected` and never scanned again. `stopScan` ran before the
  central was powered on (`API MISUSE` in Mac logs).
- **Fix:** Advertise with `CBUUID(nsuuid:)`, surface advertising-start
  failures, resume scanning after unpaired link failures, use the advertised
  local name, and gate stop/remove calls on `.poweredOn`.
- **Verification:** `PHONE_REMOTE_RUN_IOS_TESTS=1
  PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteBLEDiscoveryTests ./scripts/test.sh`
  exited 0 with shared 24/24, macOS 18/18, and iOS simulator 17/17.
- **Next action:** Install the refreshed iPhone and Mac builds, show the QR
  from the menu bar, confirm on the foreground iPhone, and watch the Mac
  status move from Scanning to Connecting/Paired. Do not look in Bluetooth
  Settings.

### 2026-09-02 — final Keychain regression checkpoint

- **State:** `storage fix covered by empty-startup and persisted-record tests`
- **Coverage:** Added a direct `MacPairingCoordinator` startup test with an
  empty isolated Keychain service, in addition to the persisted-record
  enumeration test. This exercises the exact first-launch path that previously
  produced the menu-bar storage error.
- **Verification:** The focused `scripts/test.sh` run exits 0 with shared 24/24
  and macOS 19/19. The complete five-target build exits 0, and the latest full
  simulator run remains green at iOS 17/17. A fresh rebuilt `PhoneRemoteMac.app`
  launches via `open -n` and the read-only Mac log probe exits 0.
- **Boundary:** Computer Use could not obtain a menu-bar accessibility
  snapshot, so no worker-visible click result is claimed. The owner should
  relaunch the final build, verify “Show one-time pairing QR” opens an offer,
  then repeat the physical camera confirmation and paired-device observation.

### 2026-09-02 — owner-visible pairing and debug surface

- **State:** `physical pairing observed by owner; independently corroborated`
- **Owner report:** Mac menu-bar status showed `Paired with dliao's bluetooth`
  after QR confirm. That name is the phone's Bluetooth name, not a system
  Settings pairing.
- **Independent checks:** Phone Remote is running on the iPhone. The Mac
  companion is running. The Mac Keychain has a trusted-device record for the
  pairing store. Values were not dumped.
- **Live debugging:** The Mac app has no debug console. The menu-bar window is
  the live view (Bluetooth state, pairing line, paired-device row).
  `scripts/logs-mac.sh` reads macOS system logs, but the app does not currently
  emit pairing events there. The shared metrics recorder exists in tests only.
- **Next action:** Keep using the menu-bar status for live checks. Add an
  in-app debug pane only if the owner wants one.

### 2026-09-02 — Mac loopback debug server

- **State:** `implemented and live-verified`
- **Change:** The Mac companion now serves privacy-safe JSON on loopback
  (`GET /health`, `GET /state`) from the same process. It binds
  `127.0.0.1:18765` (or the next few ports) and writes
  `/tmp/phoneremote-mac-debug.json`. `./scripts/debug-mac.sh` is the client.
  The snapshot has pairing/BLE status and display names only.
- **Verification:** macOS tests 22/22 including a loopback fetch. After
  relaunch, `./scripts/debug-mac.sh /state` showed a saved paired device
  `dliao's iPhone`, BLE `ready` with authentication still pending, and
  Accessibility `denied`. No QR or key material was present.
- **Next action:** Use `/state` for live checks. Trusted BLE reconnect does
  not restore an authenticated session yet; a new QR confirm is still
  required after the Mac app restarts.

### 2026-09-02 — trusted reconnect without QR

- **State:** `implemented; physical reconnect not run`
- **Change:** After a completed QR pair, both apps keep the trust record and
  identity in Keychain. On the next launch the phone advertises and starts a
  trusted handshake; the Mac accepts that pairing ID without a new QR, and it
  rescans after a ready disconnect so the phone can come back.
- **Verification:** Automated Mac reconnect/unknown-identity test and iPhone
  persisted-trust reconnect test added. Physical pair-then-relaunch evidence
  is still pending.
- **Still requires QR:** deleting the iPhone app, or a new unsigned Mac copy
  that cannot read the old Keychain item.

### 2026-09-02 — Mac install path vs Accessibility

- **State:** `checked; install script added`
- **Live process:** `~/Applications/PhoneRemoteMac.app` (pid running since
  19:46). Not `/Applications`. Accessibility on that copy is still `denied`.
- **This session:** the air-mouse Mac test build stayed in
  `/tmp/PhoneRemoteAirMouseMac` and was never copied to the live path. Tests
  used that throwaway copy as a test host only.
- **Change:** `scripts/install-mac.sh` now builds, replaces
  `~/Applications/PhoneRemoteMac.app`, and launches only that copy. Debug
  `/state` and the menu-bar window show the running app path.
- **Next action:** run `./scripts/install-mac.sh` (signed if the local team env
  is set), then grant Accessibility to that copy and Refresh Accessibility.

### 2026-09-02 — stable Mac install launched

- **State:** `installed and live`
- **Action:** Replaced `~/Applications/PhoneRemoteMac.app`, signed it locally,
  and launched only that copy. Finder metadata blocked xcodebuild CodeSign, so
  signing ran after copy.
- **Live check:** process path is `~/Applications/PhoneRemoteMac.app`.
  Debug `/state` reports `appPath` as that folder and Accessibility `granted`.
- **Still pending:** phone reconnect / QR confirm for an authenticated session.

### 2026-09-02 — air mouse end-to-end path

- **State:** `implemented; physical Gate E not run`
- **Gap:** The iPhone motion sink dropped every delta, and the Mac input
  adapter treated `motionPointerDelta` as unsupported, so the clutch UI never
  moved the Mac cursor.
- **Change:** The phone now sends filtered clutch deltas over the shared
  motion payload after pairing. The Mac maps that payload onto the same
  pointer safety/injection path as the trackpad. A local speed slider is on
  the Air Mouse screen. Unpaired clutch presses do not start Core Motion.
- **Verification:** macOS tests 25/25, including
  `testMotionPointerDeltaReachesSafetySinkAsPointer`. iOS simulator tests
  22/22, including `testMotionDeltaTravelsThroughProtocolAndBLEFraming`.
  Physical clutch, drift, and 32 px target measurement are still pending.
- **Next action:** Install both apps, pair, hold Air Mouse, and confirm the
  Mac cursor moves. Accessibility must already be granted or the injector
  will deny the pointer events.

### 2026-09-02 — QR pairing regression from advertise pulse

- **State:** `implemented; physical QR re-pair pending`
- **Owner report:** Normal QR pairing stopped completing after the 3-second
  advertise pulse and trusted-reconnect work.
- **Cause:** Pulse called `stopAdvertising` while a Mac was still connecting,
  which drops the in-flight link. A second start-if-allowed path could also
  reset a ready/connected peripheral back to advertising, and a saved-Mac
  reconnect could replace a live QR handshake.
- **Change:** Pulse now refreshes ads in place and no-ops while publishing or
  connected. Opening the camera pauses reconnect until Confirm. A QR failure
  stays on the QR path instead of retrying old trust.
- **Verification:** Shared 25/25, macOS 25/25, iOS simulator 24/24, including
  `testPulseDoesNotRepublishWhileServiceIsPublishing` and
  `testForegroundRefreshDoesNotDropAReadyCentral`. Signed iPhone app installed
  and launched. Live QR confirm is still an owner check.
- **Next action:** Keep Phone Remote in front, scan the Mac QR, tap Confirm,
  and wait for the Mac menu to leave Looking for iPhone.

### 2026-09-02 — iPhone app crash on open after unsigned debug dylib

- **State:** `fixed; process stays running after relaunch`
- **Owner report:** Phone Remote bounced on open and could not be used.
- **Cause:** The last device install left Xcode's Debug dylib and preview
  dylib unsigned inside the app. iOS kills an app that contains unsigned
  executable code. This was a packaging/signing miss, not a Swift crash in
  the QR pairing fix.
- **Change:** Device builds now set `ENABLE_DEBUG_DYLIB=NO`. The installer
  signs every Mach-O in the bundle, then the app. `scripts/install-phone.sh`
  passes the same flag.
- **Verification:** Signed install and launch both exit 0. A process search
  three seconds later still shows Phone Remote running.
- **Next action:** Open Phone Remote on the phone and retry QR pairing.

### 2026-09-02 — QR camera did not start after reconnect changes

- **State:** `implemented; physical camera preview still owner-run`
- **Owner report:** Scan Mac QR no longer opened the camera.
- **Cause:** `startPairing` stopped BLE advertising before starting capture,
  and the camera UI waited on an async state hop, so the preview could stay
  hidden or black.
- **Change:** QR scan starts the camera first, publishes scanner state in the
  same turn, then pauses advertising. The preview restarts capture when it
  appears. Tests require camera-before-BLE-stop and rescan after cancel/pair.
- **Verification:** Shared 26/26, macOS 27/27, iOS 29/29. Signed iPhone app
  installed and still running after launch.
- **Next action:** Tap Scan Mac QR Code and confirm the live camera preview.

### 2026-09-02 — PTT voice typing with Nemotron and S1-mini

- **State:** `implemented; physical spoken-sentence run pending`
- **Change:** Hold to talk on the iPhone now streams 16 kHz PCM to the Mac.
  The Mac rebuilds a wav, transcribes with local Nemotron ASR, cleans English
  with S1-mini by Superwhisper, and types the words through the existing
  safe text path. Audio on the wire is base64, not a JSON byte array.
- **Helper:** `scripts/transcribe-ptt.py` uses `~/stt-tts-agent` and
  `nemo-speech`. Transcripts are not written to logs or `/state`.
- **Verification:** Automated tests added for remainder flush, last-chunk
  insert, helper line parsing, and audio base64. Physical hold-to-talk and
  typed-sentence evidence is still an owner check.
- **Next action:** Rebuild both apps, pair, click a text field on the Mac,
  hold Push to talk, speak, release.

### 2026-09-02 — Live compressed PTT stream

- **State:** `implemented; physical spoken-sentence run pending`
- **Change:** Hold to talk now sends a PRA1 start frame, then IMA ADPCM
  frames as speech arrives, then a close frame on release. The Mac starts
  Nemotron ASR on the start frame and runs S1-mini plus typing only after
  close. Encrypted on the existing data channel as audio type 8.
- **Verification:** Shared IMA/frame tests and macOS stream-then-type test
  added. Physical hold-to-talk evidence is still an owner check.
- **Next action:** Reinstall both apps, pair, click a text field, hold
  Push to talk, speak, release.

### 2026-09-02 — QR scanner showed a black box

- **State:** `implemented; live camera still owner-run`
- **Owner report:** Scan Mac QR opened a black video box, not a live camera.
- **Cause:** The preview was a child layer that SwiftUI often left at size
  zero. That reads as a black feed. The capture session could also fight the
  app audio engine.
- **Change:** The preview view’s own layer is the camera layer, so it always
  matches the box size. Capture starts when that view is on screen. The
  session does not take over the shared audio session.
- **Verification:** Shared 26/26, macOS 27/27, iOS 32/32, including
  `testPreviewViewBackingLayerFillsBounds` and
  `testPreviewCallsReadyWhenMovedIntoAWindow`. Signed iPhone app installed
  and still running.
- **Next action:** Tap Scan Mac QR Code. Allow camera if asked. The box
  should show a live picture, not black.

### 2026-09-02 — iPhone camera debug log for black preview

- **State:** `debug log installed; waiting on owner scan/confirm`
- **Change:** The iPhone writes a privacy-safe camera/pairing log to its
  Documents folder and shows the last lines on screen. Pull with
  `./scripts/debug-phone.sh`. No QR text, keys, or device ids.
- **Verification:** iOS tests 33/33 including secret-field omit. Signed app
  installed and launched.
- **Next action:** Owner taps Scan Mac QR Code, then Confirm if it appears.
  Root pulls the log and fixes from the recorded camera/BLE states.

### 2026-09-02 — Confirm showed Pairing failed

- **State:** `implemented; physical confirm still owner-run`
- **Owner report:** Camera works. Confirm then Mac shows Pairing failed.
- **Cause:** Phone BLE beacon started then died at once. A second advertise
  call can error and used to tear the beacon down. Mac treated any dropped
  link before hello as a failed pair.
- **Change:** Live advertising is left alone. An advertise error no longer
  stops the beacon. Mac keeps the QR offer if hello never started.
- **Verification:** iOS tests 34/34 including live-advertisement and
  advertise-error cases. Signed iPhone and Mac apps installed.
- **Next action:** Show a fresh Mac QR, scan, Confirm. Mac should reach
  paired, not Pairing failed.

### 2026-09-02 — Scan blacks the camera after BLE stay-up

- **State:** `implemented; live camera still owner-run`
- **Owner report:** After the Confirm-fail BLE fix, Scan no longer showed a
  live camera.
- **Cause:** Logs showed BLE stop during camera startup (`preview running=no`,
  then `ble Stopped`, then `camera_start running=yes`). That leaves a black
  preview. The working case attached the preview after the session was live.
- **Change:** Pause BLE only after the camera reports it is running, then
  refresh the preview. Tests require that deferral.
- **Verification:** iOS tests 35/35 including
  `testQRScanDefersAdvertisingStopUntilCameraReportsStarted`. Signed iPhone
  app installed.
- **Next action:** Tap Scan Mac QR Code and confirm a live picture.

### 2026-09-02 — Air mouse lag, invert, and speed

- **State:** `implemented; physical feel still owner-run`
- **Change:** Cursor axes are flipped. Default speed is 1200 with a slider
  up to 4000. Smoothing is lighter. Motion packets are unreliable and extra
  samples are dropped instead of queued.
- **Next action:** Install the new iPhone app, hold Air Mouse, and check
  that pointing up/right moves the cursor up/right with less lag.

### 2026-09-02 — Signed iPhone install of air-mouse build

- **State:** `verified install/launch; physical feel still owner-run`
- **Command:** `scripts/install-phone.sh` with local `PHONE_REMOTE_SIGNING=1`
  and team/device env, then `scripts/launch-phone.sh`.
- **Build path:** Repo `DerivedData` is under iCloud Documents and adds
  Finder tags that break codesign. Signed build used
  `PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemotePhoneInstall`.
- **Evidence:** xcodebuild `BUILD SUCCEEDED`; `devicectl` installed
  `com.example.phoneremote.ios`; launch exited 0; a PhoneRemote process
  is running on the phone.
- **Not claimed:** QR re-pair, spoken-sentence typing, or air-mouse feel.
- **Next action:** Unlock the phone, confirm the app is open, hold Air
  Mouse, and check invert/speed/lag. Re-scan the Mac QR if pairing is
  stale.

### 2026-09-02 — Scripted test pass after air-mouse install

- **State:** `verified`
- **Command:** `PHONE_REMOTE_RUN_IOS_TESTS=1` `scripts/test.sh` with a temp
  DerivedData path.
- **Evidence:** Shared 28/28, macOS 27/27, iOS 35/35, all `TEST SUCCEEDED`.
- **Not claimed:** Physical air-mouse feel, spoken-sentence typing, or QR
  re-pair.
- **Next action:** Owner hold Air Mouse and check invert/speed/lag.

### 2026-09-02 — Air mouse hold lag and QR BLE pause

- **State:** `implemented; physical reinstall still needed`
- **Owner report:** Air mouse got laggier the longer the clutch was held.
  Camera scanner was black again, and QR would not pair.
- **Cause:** Motion callbacks hopped through `Task { @MainActor }` after
  already reaching main, so samples queued without bound. BLE also accepted
  more packets than the radio could drain. QR scan left the saved-Mac
  reconnect advertising, which blacks the camera and races pairing.
- **Change:** `FeatureMotionSink` adds deltas and flushes at most every
  40 ms, then calls the sender on the same main turn. Unreliable follow-on
  fragments still enqueue so a message is not left half-sent. Scan stops
  BLE only after the camera reports it is running.
- **Verification:** iOS tests 43/43 including motion-sink interval/add
  tests, unreliable drop-without-queue, and
  `testQRScanDefersAdvertisingStopUntilCameraReportsStarted`.
- **Next action:** Signed phone reinstall, then hold Air Mouse and scan a
  Mac QR.
- **Follow-up:** Scan must not stop BLE after the camera is live; that
  blacks a running preview. Lag fix kept. BLE stay-up during scan kept.
  Signed iPhone app reinstalled and launched.

### 2026-09-02 — Scan and pairing broke after other feature installs

- **State:** `implemented; physical scan/confirm still owner-run`
- **Owner report:** After other feature work, Scan showed no camera and
  pairing stopped.
- **Cause:** Logs showed the camera session running, but Scan still killed
  Bluetooth, the Mac QR had expired, and a rounded clip on the preview can
  hide the live picture. Another install also overwrote the phone app.
- **Change:** Scan no longer stops Bluetooth. Cancel resumes a saved-Mac
  reconnect. The camera preview is not clipped. Fresh signed iPhone app
  installed.
- **Verification:** iOS tests 35/35. Signed install/launch exit 0.
- **Next action:** On the Mac, show a new QR. On the phone, tap Scan, confirm
  a live picture, then Confirm.

### 2026-09-02 — Paired on Mac but ping and trackpad dead

- **State:** `implemented; physical ping still owner-run`
- **Owner report:** Mac said paired. Ping stayed disabled. Trackpad did nothing.
- **Cause:** Phone logs showed `hello_sent` every 2s. Mac already had a
  session, so it treated those hellos as app traffic and never answered.
  The phone never got a session, so ping and the pad stayed off.
- **Change:** Mac accepts a new control hello even if it thought it was
  already paired, then completes the handshake.
- **Verification:** Signed Mac app installed. Phone was still sending hello
  and should finish on the next retry.
- **Next action:** Keep Phone Remote open. Ping should enable. Swipe the pad.

### 2026-09-02 — Saved pair did not enable ping or trackpad

- **State:** `implemented; physical ping/pad still owner-run`
- **Owner report:** Mac said the iPhone was paired. Ping stayed dead. The
  trackpad did not move the cursor.
- **Cause:** The Mac list showed a saved phone name, not a live handshake.
  Phone logs stayed on `hello_sent`. A later hello could also wipe a Mac
  session that had already finished. Trackpad taps that reached the Mac
  could still be blocked by the safety gate.
- **Change:** Mac keeps a live session if a new hello arrives, answers hello
  while still subscribing, and reconnects to an already-linked phone. The
  phone marks itself paired as soon as handshake finish is sent, and it
  forwards Mac control writes even without a matching subscriber id.
- **Verification:** Scripted tests shared 28/28, macOS 29/29, iOS 37/37.
  Signed Mac app installed. Signed iPhone app installed and launched.
- **Next action:** Keep both apps in front. Tap Ping Mac. Swipe the pad.
  If macOS asks, grant Accessibility to `~/Applications/PhoneRemoteMac.app`.

### 2026-09-02 — Hold to talk BLE stream not observed

- **State:** `debug counters installed; physical hold still owner-run`
- **Owner report:** Hold to talk did not type. Asked whether audio even
  crossed BLE.
- **Evidence:** While paired, Mac last app message was a pointer move, not
  voice. `audioPhase` stayed idle. Phone debug had no PTT events. A later
  QR scan stopped the phone radio.
- **Change:** Phone logs press/send/drop/release counts only. Mac debug
  snapshot keeps `audioFrames`, `audioSamples`, and `lastAudioEvent` after
  the hold. No audio bytes, keys, or transcripts.
- **Verification:** Signed Mac and iPhone apps installed and launched. Mac
  snapshot now includes `audioFrames: 0`.
- **Next action:** Keep both apps open. Wait for Bluetooth Ready. Tap
  Request microphone access. Hold to talk, then release. Do not scan a QR.

### 2026-09-02 — Hold to talk never started the mic

- **State:** `implemented; physical hold still owner-run`
- **Owner report:** After a paired hold, phone debug showed `sent=0` and
  `ptt_press.result=notForeground`.
- **Cause:** App start stops the mic path and marks it as backgrounded. Coming
  to the front never cleared that flag, so hold refused to start capture.
- **Change:** Foreground restores the mic path. Hold also asks for mic access
  if needed, and only starts if the button is still down.
- **Verification:** iOS tests 39/39, including startup-then-foreground and
  disconnect-in-front cases. Signed iPhone app installed and launched.
- **Next action:** Wait for Bluetooth Ready. Hold to talk. Debug should show
  `ptt_press.result=started` and `sent` greater than 0.

### 2026-09-02 — Scan camera and pairing died after mic fix install

- **State:** `implemented; physical scan/pair still owner-run`
- **Owner report:** After the mic-fix phone install, Scan showed no camera
  and the Mac no longer paired.
- **Evidence:** Phone BLE stayed `Idle` with no `ble` events. Camera session
  did start (`running=yes`, 398x220) then the owner cancelled. Hold had
  started the mic first (`ptt_press.result=started`).
- **Cause:** Waiting-for-Bluetooth was treated as powered-off, which turns
  the radio off before it can advertise. A live mic session can also black
  the scanner.
- **Change:** Waiting-for-Bluetooth no longer kills advertising. Scan stops
  the mic first. Reconnect skip/start is logged.
- **Verification:** Signed iPhone app installed and launched.
- **Next action:** Keep Phone Remote open until Bluetooth is Ready, or show a
  Mac QR and Scan. The camera box should show a live picture.

### 2026-09-02 — Phone did not keep the Mac; Scan was black

- **State:** `implemented; physical QR pair still owner-run`
- **Owner report:** Phone did not store the Mac after pairing. Re-pair Scan
  showed a black camera.
- **Cause:** Phone save of the Mac was ignored if it failed. Fresh phone
  installs also wipe that store. Hold-to-talk left the audio session in
  record mode, so the camera could run and still look black.
- **Change:** Pairing now reports save ok/fail. Keychain write retries a
  replace. Scan resets the audio session and enables the preview link.
- **Verification:** iOS tests 43/43. Signed iPhone app installed and launched.
- **Next action:** Mac Show one-time pairing QR. Phone Scan, confirm a live
  picture, Confirm. Debug should show `trust_save ok=yes`.

### 2026-09-02 — Scan still black after audio-session fix

- **State:** `implemented; physical live preview still owner-run`
- **Owner report:** Scan still showed a black box. Logs had `running=yes`
  and size 398x220.
- **Cause:** The preview used the view's backing layer plus a deprecated
  portrait orientation flag. That can stay black on current iOS even when
  the camera is running.
- **Change:** Preview is a child layer whose frame is set on every layout.
  Orientation is left alone. Scan uses the back wide camera and lets the
  session take the audio session after talk is cancelled.
- **Verification:** iOS tests 43/43. Signed iPhone app installed and launched.
- **Next action:** Tap Scan Mac QR Code. The box should show a live picture.

### 2026-09-02 — Scan still black with a connected preview layer

- **State:** `implemented; physical live picture still owner-run`
- **Owner report:** Scan stayed black. Logs showed `running=yes`, `conn=yes`,
  and layer size 398x220.
- **Cause:** SwiftUI is not drawing the camera preview layer even when the
  session is live. Letting the session take the audio session also matches an
  earlier black-preview failure.
- **Change:** Scan copies camera frames into a normal image view. Audio
  session auto-takeover stays off. Debug logs `preview_frame` when frames
  arrive.
- **Verification:** iOS tests 43/43. Signed iPhone app installed and launched.
- **Next action:** Tap Scan Mac QR Code. The box should show a live picture.

### 2026-09-02 — Frames arrived but Scan box stayed empty

- **State:** `implemented; physical live picture still owner-run`
- **Owner report:** Debug logs showed camera activity. The app still showed
  no picture.
- **Evidence:** `preview_frame` reached 640 and `hasImage=yes` on dismiss.
  SwiftUI was not drawing the UIKit image view.
- **Change:** Live frames now feed a SwiftUI `Image`. Trackpad and debug
  text hide while Scan is open so the camera box is on screen.
- **Verification:** iOS tests 43/43. Signed iPhone app installed.
- **Next action:** Tap Scan Mac QR Code. A live picture should fill the box.

### 2026-09-02 — Scan picture still missing on device

- **State:** `implemented; physical live picture still owner-run`
- **Owner report:** Camera frames were running. The iPhone screen still
  showed no live picture.
- **Cause:** SwiftUI does not draw camera layers or camera images in this
  app, even when the session is live.
- **Change:** Scan now opens a full-screen UIKit camera page with the live
  preview layer. The rest of the app is covered until Cancel or Confirm.
- **Verification:** iOS tests 44/44. Signed iPhone app installed and launched.
- **Next action:** Tap Scan Mac QR Code. The whole screen should show the
  live camera, with Cancel at the bottom.

### 2026-09-02 — Scan picture missing is not a layout issue

- **State:** `implemented; physical live picture still owner-run`
- **Owner report:** Full-screen camera still showed no picture.
- **Evidence:** `scanner_present ok=yes`, layer 430x932, `running=yes`,
  `preview_frame n=492`. Permission was on. The session was not interrupted.
- **Cause:** Phone is iOS 27. Apps built with that SDK turn on deferred
  camera start. The preview layer was hooked up after the session was
  already running, so the live picture can stay blank while frames still
  arrive.
- **Change:** Reverted the full-screen camera page. The preview layer is
  connected before the session starts, and deferred start is off. Logs now
  record frame brightness, whether the layer is drawing, and the audio
  session category.
- **Verification:** iOS tests 43/43. Signed iPhone app installed.
- **Next action:** Tap Scan Mac QR Code. The box should show a live picture.

### 2026-09-02 — Black Scan picture is not live BLE

- **State:** `implemented; physical live picture still owner-run`
- **Owner question:** Is BLE broadcasting cutting off the camera?
- **Evidence:** Latest Scan had `ble=Idle` and `reconnect_skip no_trust`.
  No advertising. The preview layer was drawing (`previewing=yes`) but
  frame brightness stayed at 16/255. After Hold to talk, the audio
  session was left in Record, which can also black the camera.
- **Cause:** Not a live BLE broadcast. The extra video-frame tap added
  after the camera last worked can force a dark format. Talk also left
  Record audio on.
- **Change:** Scan is back to preview plus QR only. The mic engine is
  created only when talk starts. Record audio is cleared before the
  camera starts.
- **Issue log:** `docs/camera_preview_black.md` lists every Scan-camera
  attempt, what the logs proved, and what not to try again.
- **Verification:** iOS tests 43/43. Signed iPhone app installed.

### 2026-09-02 — Camera live confirmed; close-up focus fix for iPhone 15 Pro Max

- **State:** `implemented; ready for owner install and QR scan`
- **Owner report:** Camera is now working and live. The camera is not focusing enough on the QR code and not picking it up.
- **Cause:** 
  1. Camera live fix: Restored `.high` preset, explicitly called `runDeferredStartWhenNeeded()` for iOS 26/27 deferred start mode, and ensured immediate `CATransaction` frame layout.
  2. Close-up focus issue: iPhone 15 Pro Max wide camera has a physical minimum focus distance of ~20 cm (8 inches). Holding the phone closer blurs the lens. The camera selector was also restricted to `.builtInWideAngleCamera`, preventing iOS from switching to the Ultra Wide macro lens.
- **Change:**
  - Prioritized `.builtInTripleCamera` and `.builtInDualWideCamera` so iOS automatically switches to macro mode at close range.
  - Enabled continuous autofocus, unrestricted range, and continuous autoexposure.
  - Automatically set `videoZoomFactor = 2.0` (lossless 48MP sensor crop) when `device.minimumFocusDistance > 100`, letting the user hold the phone at a comfortable distance (20–30 cm / 8–12 in) with sharp focus.
  - Added tap-to-focus gesture on preview window.
  - Added 1x/2x quick zoom buttons and user tip ("Tap to focus • Hold 8–12 in (20–30 cm) away").
- **Verification:** Unit tests pass 43/43 (`PHONE_REMOTE_RUN_IOS_TESTS=1`). Signed iPhone app build succeeded.
- **Next action:** Unlock phone and install updated signed build with `./scripts/install-phone.sh`. Hold phone 8–12 inches away from Mac QR code (or use 2x zoom / tap to focus).
