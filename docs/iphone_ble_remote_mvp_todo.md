# iPhone BLE Remote for Mac — MVP Ticket Backlog

Source of truth: [`iphone_ble_remote_mvp_scope.md`](./iphone_ble_remote_mvp_scope.md)

This backlog decomposes the MVP scope into small implementation tickets suitable for one coding agent at a time. It does not authorize product work beyond the source scope.

## Live implementation status

Last checkpoint: 2026-09-02 — Air mouse hold-lag fixed: add leftover moves and send at most every 40 ms. Signed iPhone app reinstalled. Hold Air Mouse and scan a Mac QR. Detailed checkpoints are recorded in [`implementation_progress.md`](./implementation_progress.md).

| Stream | Tickets | Status | Owner |
|---|---|---|---|
| Foundation/shared | FND-001–003, PRO-001–002, SIM-001, OBS-001 | FND-001/PRO/SIM/OBS automated complete; FND-002 XcodeGen pending; FND-003 signed install/launch pass, iPhone log collection blocked | Root integration |
| BLE/pairing | BLE-001–005, PAIR-001–005 | Authenticated QR-to-BLE bridge and Mac paired-device UI implemented/tested; BLE-005 and physical QR/trust evidence pending | Root integration |
| Safety/features | SAFE-001–004, PAD-001–002, KEY-001–002, MOT-001–002, AUD-001–003, LIFE-001 | Implemented/tested with mocks/simulator; physical input, motion, audio, and lifecycle evidence pending | Root integration |
| Verification/decision | QA-001–002 | Hardware matrix and go/no-go blocked | Root |

Status meanings: `Pending` = not started; `In progress` = assigned or under integration; `Blocked` = a concrete external/toolchain blocker is recorded; `Complete` = acceptance criteria and required evidence verified by root.

### Root-verified ticket snapshot

The following checkboxes are now checked because their acceptance criteria are
covered by repository documentation and deterministic automated evidence. A
ticket that requires a physical run remains unchecked even when its code and
mock/simulator tests are complete.

- Complete: FND-001, PRO-001, PRO-002, SIM-001, OBS-001, BLE-001, BLE-004,
  PAIR-003, SAFE-001, SAFE-003, MOT-001.
- Physical loop evidence (not a ticket completion): signed target-specific
  install and launch both pass; the app process remains present on the paired
  iPhone. `logs-phone.sh` was exercised but is blocked by Xcode 27's generic
  `CoreDeviceCLISupport.DiagnoseError error 0`, so FND-003 and Gate A remain
  unchecked.
- Implemented but awaiting required hardware/manual evidence: FND-002,
  FND-003, BLE-002, BLE-003, BLE-005, PAIR-001, PAIR-002, PAIR-004, PAIR-005,
  SAFE-002, SAFE-004, PAD-001, PAD-002, KEY-001, KEY-002, MOT-002, AUD-001,
  AUD-002, AUD-003, LIFE-001, QA-001, QA-002.

### Checkpoint log

- 2026-09-02: Repository initialized; source scope moved into `docs/`; 33-ticket backlog created.
- 2026-09-02: Three Luna Max implementation streams dispatched with non-overlapping file ownership. Root owns integration, cross-module tests, physical/simulator smoke checks, and final ticket verification.
- 2026-09-02: Xcode 27.0 is available; no iOS simulator is listed; connected iPhone reports `connected (no DDI)`. Physical Gate A evidence remains pending trust/Developer Mode/DDI and a successful install/launch/log capture.
- 2026-09-02: BLE/pairing checkpoint: crypto and framing files are present and standalone CryptoKit type-check passed; Core Bluetooth shells, QR UX, attack tests, target integration, and physical evidence remain pending.
- 2026-09-02: Generated project lists six expected targets/schemes, but the first build probe exposed an Xcode 27 script issue (`-target` with `-derivedDataPath`); foundation must fix the invocation before Gate A can advance.
- 2026-09-02: Direct scheme build reached compilation but exposed duplicated `Shared/Shared/...` paths from the fallback generator; foundation is fixing generator path handling before any build ticket is checked.
- 2026-09-02: Shared target now reaches Swift 6 compilation; BLE/GATT value types need justified `Sendable` annotations for strict-concurrency builds before integration can pass.
- 2026-09-02: BLE/pairing app consumers now import `PhoneRemoteShared`; full target-membership and deployment-target build verification remains pending.
- 2026-09-02: BLE/pairing implementation checkpoint includes Core Bluetooth shells, framing/scheduler, QR/session/trust wrappers, and Gate B/C templates; worker strict type-check passed, but full project/tests/hardware evidence is pending.
- 2026-09-02: Root strict concurrency check found the macOS AX prompt global needs isolation/annotation; safety worker is fixing before SAFE tickets can be verified.
- 2026-09-02: Final reconciliation passed the five-target build, strict Swift 6 complete-concurrency type-check, generated-project target listing, static placeholder scan, scripted shared/macOS/iOS suites (23/23, 14/14, 15/15), and deterministic 2,000-input protocol fuzz. Physical Gates A–F remain unchecked because the target phone is `connected (no DDI)` with Developer Mode disabled and the second phone is unavailable.
- 2026-09-02: A signing-disabled physical-SDK build passed, but the bounded install probe failed to mount the developer disk image (CoreDevice 12040; phone locked). Developer Mode is still disabled; FND-003 and all physical gates remain unchecked until the owner completes the GUI prerequisites.
- 2026-09-02: Owner enabled Developer Mode and restarted; `devicectl` now reports the target as `available (paired)`. A follow-up unsigned install probe still hit the locked-device/DDI error, and this Mac has zero signing identities. FND-003 and all physical gates remain unchecked pending unlock and local team signing.
- 2026-09-02: `device info details` confirms Developer Mode Enabled. `device info ddiServices` still reports CoreDevice 12040 because the device was locked for the service request; keep it unlocked on-screen. The Mac still has zero local signing identities, so FND-003 and all physical gates remain unchecked pending signed install/launch/log evidence.
- 2026-09-02: `device info details` confirms Developer Mode Enabled and `device info ddiServices` reports compatible/usable DDI content. The unsigned install probe now reaches CoreDevice 3002 / MIInstaller 13 (`No code signature found`); the Mac still has zero local signing identities, so FND-003 and all physical gates remain unchecked pending signed install/launch/log evidence.
- 2026-09-02: Physical service readiness is confirmed (paired, Developer Mode Enabled, usable DDI); the unsigned install probe fails only at code signing (CoreDevice 3002 / MIInstaller 13). Create/select an Apple Development certificate in Xcode before attempting the signed install; all physical tickets remain unchecked until measured evidence is captured.
- 2026-09-02: The owner signed into Xcode and local Apple Development provisioning became available. A target-specific signed build and `devicectl device install app` both exited 0; the embedded profile contains the supplied phone, and no signing values or identifiers were recorded.
- 2026-09-02: The first signed launch exposed a packaging defect: the shared framework used an absolute install name, then an app runpath that omitted the embedded `Frameworks` directory. `LD_DYLIB_INSTALL_NAME=@rpath/PhoneRemoteShared.framework/PhoneRemoteShared` plus app runpaths including `@executable_path/Frameworks` fixed the loader path; deep strict code-sign verification passed.
- 2026-09-02: The repeatable signed workflow (`install-phone.sh` with local team/UDID environment) exited 0, and `launch-phone.sh` exited 0. A follow-up process query found the Phone Remote app still running on the iPhone, so the signed install/launch loop is verified without claiming any feature gate.
- 2026-09-02: `logs-phone.sh` was retried with the phone paired, unlocked, and the app running. It exited 1 with Xcode 27 `CoreDeviceCLISupport.DiagnoseError error 0` and produced no diagnostic archive; this is a tooling boundary, not evidence of an app crash. Gates B–F and the hardware portions of FND-003 remain pending manual interaction and measurements.
- 2026-09-02: After the runpath change, the full regression remains green: `scripts/build.sh` exit 0 and `scripts/test.sh` exit 0 with shared 23/23, macOS 14/14, and iOS simulator 15/15. The generated project was regenerated sequentially after a deliberate concurrent-generation race exposed by parallel checks.
- 2026-09-02: The freshly built Mac menu-bar app launched via `open -n`, and the read-only `PHONE_REMOTE_LOG_WINDOW=1m ./scripts/logs-mac.sh` probe exited 0. FND-003 remains unchecked only because the physical iPhone diagnostics command is still toolchain-blocked.
- 2026-09-02: Camera preview and pairing bridge checkpoint: the iPhone preview layer now sizes itself during UIKit layout; scanner confirmation starts foreground BLE advertising; the existing framed control channel carries hello/server-hello/finish; the Mac consumes the QR offer by pairing ID and only then persists a trusted phone and shows its paired name. Automated verification is green at shared 24/24, macOS 16/16, and iOS simulator 15/15. Physical camera/QR confirmation and paired-device UI observation remain pending.
- 2026-09-02: The refreshed physical-SDK app was signed locally with the available Apple Development certificate plus the existing device-valid development profile after the normal CLI account/profile lookup failed. Deep strict code-sign verification, device install, launch, and delayed process liveness all passed. Physical camera preview, QR confirmation, BLE authentication, and the Mac paired-device row are still awaiting the interactive run.
- 2026-09-02: macOS Keychain pairing startup was fixed after reproducing `errSecParam` from `kSecMatchLimitAll` plus `kSecReturnData`. `KeychainTrustedDeviceStore.allRecords()` now enumerates account attributes and fetches each value individually, with an 18/18 macOS regression suite. The full scripted run also passed shared 24/24 and iOS simulator 17/17. Physical QR/camera/paired-row evidence remains pending because the menu-bar accessibility snapshot was unavailable to the worker.
- 2026-09-02: BLE discovery check: the iPhone is not supposed to appear as a pairable device in Mac Bluetooth Settings. The Mac app also has no device picker; it scans for the custom service and auto-connects after the phone confirms the QR. Advertising now uses `CBUUID`, advertising start failures stop the peripheral, unpaired Mac connect failures resume scanning, and `stopScan`/`stopAdvertising` are gated on powered-on. Automated verification is shared 24/24, macOS 18/18, iOS 17/17. Physical QR confirm still required.
- 2026-09-02: Owner observed the Mac menu-bar status `Paired with dliao's bluetooth` after QR confirm. Root independently found the iPhone and Mac apps running and a trusted-device Keychain record for the Mac pairing store. The Mac companion still has no live debug console; menu-bar status is the in-app view, and `logs-mac.sh` currently captures Apple system noise rather than pairing events.
- 2026-09-02: Follow-up Keychain regression coverage adds an empty-service `MacPairingCoordinator` startup/offer test. The focused script passes shared 24/24 and macOS 19/19; the prior full run passed iOS simulator 17/17. The rebuilt Mac app launches and produces normal process-scoped logs, but the worker could not inspect the menu-bar accessibility tree, so the visible QR action and physical camera/paired-row flow remain owner checks.
- 2026-09-02: Mac loopback debug server is live at `http://127.0.0.1:18765/state` (`./scripts/debug-mac.sh`). A live fetch showed saved paired device `dliao's iPhone`, BLE ready with authentication pending after relaunch, and Accessibility denied. Payload excludes QR/keys. macOS tests 22/22.
- 2026-09-02: QR pairing regression from advertise-pulse/reconnect: pulse no longer calls `stopAdvertising`; start-if-allowed no-ops while publishing/connected/ready; QR scan pauses saved-Mac reconnect; QR handshake failure no longer falls back to old trust. iOS tests 24/24 including pulse/ready-refresh cases. Shared 25/25, macOS 25/25. Signed iPhone build installed and launched. Physical QR confirm still owner-run.
- 2026-09-02: iPhone open-crash after that install: the app bundle contained unsigned Debug/preview dylibs, so iOS killed it on launch. Device builds now disable the Debug dylib and sign every binary. Fresh install/launch stay running.
- 2026-09-02: QR camera start regression: scan now starts capture before BLE teardown and publishes scanner state in the same turn. iOS tests 29/29 including camera-before-BLE-stop and rescan-after-cancel/pair. Signed app installed and still running.
- 2026-09-02: PTT voice typing: iPhone now sends PCM over BLE while Hold to talk is down. Mac rebuilds a wav, runs local Nemotron plus S1-mini, and types the result. Automated tests cover flush, last-chunk insert, and base64 audio. Physical spoken-sentence evidence is pending.
- 2026-09-02: QR black preview: camera layer is now the preview view itself so it always fills the box; capture starts when the view is on screen. iOS tests 32/32 including backing-layer bounds and window-ready. Signed app installed and still running.
- 2026-09-02: Live compressed PTT: start/data/close PRA1 frames over BLE with IMA ADPCM. Mac starts Nemotron on start and types after close plus S1-mini.
- 2026-09-02: Air mouse: invert pitch/yaw, raise speed slider to 4000, drop extra samples instead of queueing.
- 2026-09-02: Signed iPhone install via `scripts/install-phone.sh` (temp DerivedData, local team/signing env) exited 0; `scripts/launch-phone.sh` launched the bundle. Physical air-mouse feel and QR re-pair remain owner checks.
- 2026-09-02: `scripts/test.sh` with iOS execution passed shared 28/28, macOS 27/27, iOS 35/35.
- 2026-09-02: Air mouse hold-lag: coalesce and add deltas, send at most every 40 ms, no extra Task hop. QR scan stops BLE only after the camera is running. iOS tests 43/43. Physical reinstall still needed.
- 2026-09-02: Ping and trackpad stayed dead while the Mac still showed a saved phone. Handshake now keeps a live Mac session, the phone marks itself paired as soon as the handshake finishes, and Mac/phone apps were reinstalled. Scripted tests: shared 28/28, macOS 29/29, iOS 37/37. Physical ping/pad remain owner checks.

## Working rules for every ticket

- Work on exactly one ticket. Do not pull work forward from a dependent ticket.
- Read the source scope and the ticket's dependencies before changing code.
- Keep the wire protocol transport-neutral: no Core Bluetooth, Core Graphics, Core Motion, or AVFoundation types in shared protocol models.
- Do not add Wi-Fi, cloud relay, generic HID, background control, arbitrary macros, shell execution, clipboard sync, file transfer, or remote app launching.
- Never log QR secrets, keys, typed text, transcripts, or audio payloads.
- Add or update tests for every behavior changed. A ticket is not complete merely because the project builds.
- Record hardware-only verification with device models, OS versions, timestamp, duration, and observed metrics.
- If a dependency's interface is insufficient, stop and describe the gap; do not silently redesign completed modules.
- Check a ticket only after all acceptance criteria pass and its required evidence is recorded.

## Stable repository conventions

Unless an earlier ticket records a justified change, use this layout:

```text
PhoneRemote/
├── project.yml
├── Config/
├── Shared/
│   ├── Protocol/
│   ├── Crypto/
│   └── TestTransport/
├── iPhone/
│   ├── Bluetooth/
│   ├── Pairing/
│   ├── Trackpad/
│   ├── MotionPointer/
│   └── Audio/
├── Mac/
│   ├── Bluetooth/
│   ├── Pairing/
│   ├── InputInjection/
│   └── Transcription/
├── Tests/
└── scripts/
```

The command surface established by the foundation tickets should remain stable:

```text
./scripts/generate.sh
./scripts/build.sh
./scripts/test.sh
./scripts/install-phone.sh
./scripts/launch-phone.sh
./scripts/logs-phone.sh
./scripts/logs-mac.sh
```

## Definition of done

Every implementation ticket must leave:

- A focused code change within the ticket's named modules.
- Automated tests that fail before the change and pass after it, where automation is possible.
- No new compiler warnings.
- A short verification note in the PR or commit description listing commands run and results.
- Documentation updates for any public interface, CLI command, permission, manual step, or measured result changed.

---

## Phase 0 — Decisions and foundation

### - [x] FND-001 — Pin the prototype toolchain and target device matrix

**Priority:** P0  
**Depends on:** None  
**Unblocks:** FND-002, FND-003

**Goal:** Turn “supported current iOS/macOS” into explicit, reproducible build inputs without creating app code.

**In scope:** Record Xcode, Swift, XcodeGen, minimum deployment targets, bundle-ID prefix convention, target iPhone/Mac models, and OS versions. Document the separate non-admin macOS test account requirement and unavoidable GUI signing/device-trust steps.

**Out of scope:** Installing tools, generating projects, choosing production distribution, or storing credentials.

**Acceptance criteria:**

- `docs/development_environment.md` names every pinned version and target device.
- The document separates CLI steps from Apple ID, signing, device trust, and Developer Mode GUI steps.
- No Apple ID, team ID, UDID, signing certificate, secret, or local absolute path is committed.
- Open uncertainties are marked `TBD` with an owner and blocking ticket rather than guessed.

**Verification:** A new agent can list the required tools and both target OS versions using only the document.

### - [ ] FND-002 — Scaffold the XcodeGen workspace and build targets

**Priority:** P0  
**Depends on:** FND-001  
**Unblocks:** FND-003, PRO-001

**Goal:** Create the smallest generated workspace containing iPhone, macOS, shared, and test targets.

**In scope:** `project.yml`, configuration files, empty SwiftUI app entry points, shared module, unit-test targets, and `.gitignore` rules for generated/local Apple artifacts.

**Out of scope:** BLE, pairing, input injection, gestures, motion, audio, business UI, or generated `.xcodeproj` files in Git.

**Acceptance criteria:**

- `xcodegen generate` succeeds from a clean checkout.
- Both app targets and all unit-test targets compile from the command line.
- Shared code is importable by both apps and tests.
- Generated projects, DerivedData, provisioning profiles, and user data remain untracked.

**Verification:** Run project generation plus one clean CLI build for each app destination.

### - [ ] FND-003 — Add the stable CLI build, test, device, launch, and log commands

**Priority:** P0  
**Depends on:** FND-002  
**Unblocks:** All implementation tickets

**Goal:** Make the normal development loop executable without routine Xcode GUI use.

**In scope:** The seven scripts listed in “Stable repository conventions,” usage help, environment-variable validation, readable failures, and README instructions.

**Out of scope:** Committing developer-specific IDs, bypassing signing/security, CI/CD, or feature implementation.

**Acceptance criteria:**

- Generate, build, and test scripts work from a clean checkout.
- Device scripts validate required environment variables before invoking Apple tooling.
- Mac launch/log collection works from CLI; physical iPhone install, launch, and log collection are documented and exercised once.
- README contains only unavoidable GUI steps and contains no credentials or device identifiers.

**Verification:** Capture command names, exit codes, and target device/OS in `docs/verification/gate-a-toolchain.md`.

---

## Phase 1 — Shared protocol, simulation, and observability

### - [x] PRO-001 — Define transport-neutral protocol models and version 1 envelope

**Priority:** P0  
**Depends on:** FND-002, FND-003  
**Unblocks:** PRO-002, SIM-001, BLE-001, SAFE-001

**Goal:** Define the complete MVP message vocabulary before any BLE or input feature depends on it.

**In scope:** Protocol version, session ID, monotonic sequence number, timestamp, message type, authenticated payload boundary, and typed payloads for heartbeat/input state, pointer, scroll, buttons, text, allowlisted hotkeys, motion pointer, audio, acknowledgement, status, and error.

**Out of scope:** Encryption implementation, BLE framing, feature behavior, Apple framework types, or forward-compatible messages not needed by the MVP.

**Acceptance criteria:**

- Each MVP message has a documented schema, units, bounds, and reliable/unreliable delivery classification.
- Encoding and decoding round trips every message type.
- Models use fixed-width primitives, byte arrays, strings, and protocol-owned enums only.
- Version mismatch and unknown message behavior are explicit and test-covered.

**Verification:** Run the shared protocol unit-test suite through `./scripts/test.sh`.

### - [x] PRO-002 — Harden protocol validation and decoder failure behavior

**Priority:** P0  
**Depends on:** PRO-001  
**Unblocks:** BLE-004, PAIR-003

**Goal:** Ensure untrusted bytes fail deterministically without crashes or excessive allocation.

**In scope:** Size limits, numeric bounds, UTF-8 validation, enum validation, malformed/truncated input, duplicate and out-of-order classification, unknown versions/types, and fuzz/property tests for the decoder.

**Out of scope:** Cryptographic authentication, retries, BLE chunking, or product UI.

**Acceptance criteria:**

- Malformed, oversized, truncated, duplicate, and out-of-order cases have explicit expected results.
- Decoder rejects allocation claims above documented limits before allocating them.
- Fuzz/property tests run a documented minimum corpus/iteration count without a crash.
- Test failures identify the seed/input needed to reproduce them.

**Verification:** Run protocol tests and the bounded fuzz command documented by this ticket.

### - [x] SIM-001 — Implement the deterministic in-process simulated transport

**Priority:** P0  
**Depends on:** PRO-001, FND-003  
**Unblocks:** OBS-001, SAFE-003, PAD-001, KEY-001, MOT-002

**Goal:** Let protocol and feature code run without physical BLE.

**In scope:** Bidirectional endpoints, connect/disconnect, ordered delivery, configurable delay, loss, duplication, reordering, backpressure, deterministic clock/random seed, and test-only inspection hooks.

**Out of scope:** Core Bluetooth imports, encryption, production persistence, or app feature UI.

**Acceptance criteria:**

- Tests reproduce the same event trace with the same seed.
- Tests cover delay, loss, duplication, reordering, disconnect, and bounded-queue overflow.
- No simulated transport type leaks into protocol message definitions.
- Both app modules can depend on the transport interface without depending on its test implementation.

**Verification:** Run its unit tests twice with the same seed and compare the emitted trace.

### - [x] OBS-001 — Add privacy-safe metrics and lifecycle event logging

**Priority:** P1  
**Depends on:** PRO-001, SIM-001  
**Unblocks:** BLE-005, AUD-002, QA-001

**Goal:** Establish measurement and redaction rules before features emit logs.

**In scope:** Structured counters/events for connection state, packet counts by type, gaps, duplicates, retries, acknowledgements, latency histogram, heartbeat releases, audio gaps/duration, motion rates, and lifecycle transitions; injectable clock; test log sink.

**Out of scope:** Analytics services, remote telemetry, typed content, transcripts, payload bytes, QR material, or keys.

**Acceptance criteria:**

- Logging API has no field intended for typed text, transcript, audio payload, QR secret, or key material.
- Redaction tests use sentinel secrets and prove none appear in captured output.
- Counters and latency buckets are deterministic under the simulated transport.
- Logs are local and have a documented retention/removal procedure.

**Verification:** Run observability/redaction tests and inspect the captured fixture for all sentinel values.

---

## Phase 2 — BLE transport proof

### - [x] BLE-001 — Specify the custom GATT service and byte framing contract

**Priority:** P0  
**Depends on:** PRO-001, PRO-002  
**Unblocks:** BLE-002, BLE-003, BLE-004

**Goal:** Freeze the minimum BLE-facing contract independently of either app implementation.

**In scope:** Service/characteristic UUIDs, characteristic properties, direction, framing header, negotiated payload size, control/data separation, ordering expectations, and connection state machine.

**Out of scope:** Core Bluetooth code, crypto handshake details, feature messages, or performance claims.

**Acceptance criteria:**

- `docs/ble_gatt_contract.md` defines every UUID and byte field once.
- The contract supports bidirectional messages and variable negotiated write/notify sizes.
- Invalid length, unknown frame type, and mid-message disconnect behavior are specified.
- At most one custom service is advertised by the iPhone MVP.

**Verification:** Review protocol size limits against the smallest documented frame payload and show that fragmentation is bounded.

### - [ ] BLE-002 — Implement the iPhone BLE peripheral transport shell

**Priority:** P0  
**Depends on:** BLE-001, FND-003  
**Unblocks:** BLE-004

**Goal:** Advertise the custom service and expose the GATT endpoints while the iPhone app is foregrounded.

**In scope:** `CBPeripheralManager` lifecycle, service publication, advertising, subscriber tracking, raw frame ingress/egress hooks, Bluetooth permission/state UI, and local state tests behind adapters.

**Out of scope:** Pairing, encryption, protocol retry, gestures, background execution, or microphone access.

**Acceptance criteria:**

- Advertising begins only in the correct powered-on, foreground app state.
- Advertising and subscriptions stop cleanly on state loss or app transition.
- Exactly the service and characteristics from BLE-001 are exposed.
- Unit tests cover powered-off, unauthorized, reset, subscriber add/remove, and queue-full callbacks.

**Verification:** Mac-side BLE inspection discovers the service without using macOS Bluetooth Settings.

### - [ ] BLE-003 — Implement the Mac BLE central transport shell

**Priority:** P0  
**Depends on:** BLE-001, FND-003  
**Unblocks:** BLE-004

**Goal:** Discover, connect to, and subscribe to the iPhone service by UUID.

**In scope:** `CBCentralManager` lifecycle, service-filtered scan, connection/discovery/subscription state machine, raw frame hooks, timeout/cancel behavior, and minimal connection status UI.

**Out of scope:** Bluetooth Settings UI, pairing trust, auto-trust, feature messages, or input injection.

**Acceptance criteria:**

- Scan is restricted to the custom service UUID.
- Connection becomes ready only after required characteristics are validated and subscribed.
- Disconnect, malformed service, missing characteristic, powered-off, and unauthorized states terminate safely.
- State-machine tests use adapters/mocks and do not require physical BLE.

**Verification:** The physical Mac discovers and connects to the foreground iPhone without Bluetooth Settings.

### - [x] BLE-004 — Add BLE fragmentation, reassembly, flow control, and reliable frames

**Priority:** P0  
**Depends on:** BLE-002, BLE-003, PRO-002  
**Unblocks:** BLE-005, PAIR-003

**Goal:** Carry complete protocol envelopes over variable BLE payload sizes without unbounded queues.

**In scope:** Fragmentation/reassembly, bounded buffers, negotiated maximum write lengths, backpressure, acknowledgement correlation, retry limits, timeout, duplicate suppression, and disconnect cleanup.

**Out of scope:** Cryptographic authentication, feature-specific retry policy beyond protocol classification, or benchmark tuning.

**Acceptance criteria:**

- Boundary-size tests cover zero/minimum, exact frame, one-byte-over, maximum envelope, and oversized input.
- Loss/duplicate/reorder simulations produce documented results without duplicate reliable delivery.
- Queue and reassembly memory have explicit upper bounds.
- Disconnect clears partial messages, timers, and pending acknowledgements.

**Verification:** Run deterministic transport tests across at least three simulated payload sizes.

### - [ ] BLE-005 — Run the 100 Hz BLE soak, latency, stall, and radio recovery proof

**Priority:** P0  
**Depends on:** BLE-004, OBS-001  
**Unblocks:** PAIR-001, PAD-001, MOT-002, AUD-001

**Goal:** Decide whether the basic BLE link meets Gate B before feature work relies on it.

**In scope:** Synthetic pointer packets at 100 Hz for 30 minutes, round-trip measurement, stall detection, sequence accounting, Bluetooth off/on recovery, and a reproducible hardware procedure.

**Out of scope:** Pairing security, real input injection, gesture UI, audio, or hiding failed metrics.

**Acceptance criteria:**

- p95 round-trip latency is at most 50 ms.
- No unexplained transport stall exceeds 250 ms.
- Packet totals reconcile with gaps, duplicates, and dropped/backpressured counts.
- Bluetooth off/on reaches a safe disconnected state and reconnects.
- Results record device/OS versions, duration, timestamps, and raw aggregate metrics without content.

**Verification:** Save the procedure and result in `docs/verification/gate-b-ble.md`; if the gate fails, leave it failed and document evidence.

---

## Phase 3 — QR pairing and authenticated sessions

### - [ ] PAIR-001 — Define and generate expiring one-time QR pairing tokens on Mac

**Priority:** P0  
**Depends on:** BLE-005  
**Unblocks:** PAIR-002, PAIR-003

**Goal:** Display a precisely specified, single-use pairing offer without yet trusting a phone.

**In scope:** Versioned token schema containing Mac display name, ephemeral public key, random secret, pairing ID, issue/expiry times; cryptographically secure randomness; 120-second-or-shorter expiry; QR rendering; one-active-token state.

**Out of scope:** Scanner, BLE handshake, persisted trust, or accepting a token.

**Acceptance criteria:**

- Schema and canonical encoding are documented with size bounds.
- Each token has new ephemeral key material, secret, and pairing ID.
- Expired/replaced tokens become unusable in the token state machine.
- UI clearly shows expiry/cancel state and does not log token contents.

**Verification:** Unit tests use an injected clock to cover issue, cancel, replace, and expiry boundaries.

### - [ ] PAIR-002 — Implement iPhone QR scanning, validation, and one confirmation

**Priority:** P0  
**Depends on:** PAIR-001, FND-003  
**Unblocks:** PAIR-003

**Goal:** Parse a pairing offer and obtain exactly one explicit user confirmation before advertising for pairing.

**In scope:** Camera permission flow, scanner, strict token decoding, safe Mac-name preview, confirmation/cancel UI, expiry handling, and transfer of validated token data to the pairing coordinator.

**Out of scope:** Cryptographic session establishment, persisted trust, automatic confirmation, or background scanning.

**Acceptance criteria:**

- Malformed, oversized, unknown-version, and expired QR values are rejected before BLE advertising.
- One explicit confirmation is required; cancel performs no pairing action.
- Camera use ends after success, cancel, or app transition.
- UI/logs never expose the secret or full encoded token.

**Verification:** Automated parser/state tests plus one physical scan/cancel/confirm pass.

### - [x] PAIR-003 — Implement X25519/HKDF authenticated pairing and encrypted sessions

**Priority:** P0  
**Depends on:** PAIR-002, BLE-004, PRO-002  
**Unblocks:** PAIR-004, PAIR-005, SAFE-001

**Goal:** Turn a confirmed QR offer into an authenticated encrypted BLE session with replay protection.

**In scope:** CryptoKit X25519, HKDF with documented context binding, authenticated encryption, transcript binding to pairing/session IDs and roles, monotonic encrypted sequence checks, explicit failure states, and key zeroization where APIs permit.

**Out of scope:** Inventing cryptographic primitives, cloud identity, OS Bluetooth bonding, or long-term trust storage.

**Acceptance criteria:**

- Both sides derive matching session keys only for the same valid token and handshake transcript.
- Modified ciphertext, role reflection, wrong secret/key, replayed envelope, and sequence rollback fail closed.
- A session ID/key is never reused after reconnect or failed pairing.
- No plaintext protocol message is accepted after the authenticated session boundary.

**Verification:** Deterministic handshake vectors and negative tests run through `./scripts/test.sh`.

### - [ ] PAIR-004 — Persist, reconnect, list, and revoke trusted devices

**Priority:** P0  
**Depends on:** PAIR-003  
**Unblocks:** PAIR-005, LIFE-001

**Goal:** Reconnect known devices without QR while never silently trusting a new device.

**In scope:** Keychain-backed device identity/trust records on both platforms, known-device authenticated reconnect, minimal trusted-device display, revoke/delete flow, corruption handling, and storage abstraction tests.

**Out of scope:** iCloud sync, multiple user accounts, migration from production schemas, or trust based only on BLE identifiers/display names.

**Acceptance criteria:**

- Trusted reconnect performs a fresh authenticated session handshake.
- Unknown or revoked identities cannot reconnect.
- Deleting trust on either device forces a new QR pairing.
- Corrupt/missing Keychain data fails closed and can be removed without crashing.

**Verification:** Tests use an in-memory Keychain adapter; physical test covers pair, reconnect, revoke on each side, and rejected reconnect.

### - [ ] PAIR-005 — Execute the pairing attack and log-redaction matrix

**Priority:** P0  
**Depends on:** PAIR-004, OBS-001  
**Unblocks:** SAFE-002, PAD-001, KEY-001, AUD-001

**Goal:** Close Gate C with explicit adversarial evidence.

**In scope:** Modified fields, invalid public key, wrong secret, expired token boundaries, replay before/after use, unknown device reconnect, corrupted ciphertext, sequence replay/rollback, cancellation, and secret sentinel searches in logs.

**Out of scope:** Penetration testing outside the apps, OS Bluetooth attacks, or claiming production security certification.

**Acceptance criteria:**

- Every matrix case has expected and observed outcomes.
- Token use is atomic: concurrent/repeated attempts yield at most one success.
- All failures leave no trusted record and no usable authenticated session.
- Captured logs contain none of the test secrets, keys, QR payloads, or plaintext content.

**Verification:** Save matrix and results in `docs/verification/gate-c-pairing.md`.

---

## Phase 4 — Mac input safety boundary

### - [x] SAFE-001 — Build the pure input-safety state machine and command policy

**Priority:** P0  
**Depends on:** PRO-001, PAIR-003  
**Unblocks:** SAFE-002, SAFE-003, SAFE-004

**Goal:** Create the only policy layer allowed to authorize remote input, independent of Core Graphics.

**In scope:** Authenticated/unauthenticated, active/paused, locked/unlocked, awake/asleep, logged-in/logged-out states; explicit held mouse/modifier state; allowlisted command types; `releaseAllInputs()` decision generation; injected clock.

**Out of scope:** Posting OS events, Accessibility permission UI, BLE implementation, or feature UI.

**Acceptance criteria:**

- Input is denied unless authenticated, active, unlocked, awake, and logged in.
- Every transition to a non-controllable state emits releases for all held state exactly once.
- Startup begins with no remotely held state and a safe non-controlling policy.
- Table-driven tests cover every state transition and forbidden command class.

**Verification:** Run the pure state-machine suite without macOS accessibility permissions.

### - [ ] SAFE-002 — Add the macOS Accessibility permission flow and Core Graphics event sink

**Priority:** P0  
**Depends on:** SAFE-001, PAIR-005  
**Unblocks:** SAFE-003, PAD-001, KEY-001

**Goal:** Translate already-authorized safety commands into public macOS input APIs.

**In scope:** Accessibility trust detection/prompt guidance, `CGEvent`-backed sink, mock sink, pointer movement, scroll, mouse transitions, Unicode text, fixed physical key transitions, and error reporting.

**Out of scope:** Input Monitoring, Screen Recording, Full Disk Access, admin privilege, scripts, macros, or policy decisions bypassing SAFE-001.

**Acceptance criteria:**

- App requests only Accessibility permission.
- Event posting is reachable only through the safety-policy interface.
- Unit tests assert exact ordered sink events without posting real input.
- Missing/revoked permission stops control and triggers release handling.

**Verification:** Test with permission absent, granted, and revoked; record manual steps without developer-specific identifiers.

### - [x] SAFE-003 — Implement reliable transitions, deduplication, and the 500 ms watchdog

**Priority:** P0  
**Depends on:** SAFE-001, SAFE-002, SIM-001  
**Unblocks:** SAFE-004, PAD-002, KEY-002, QA-001

**Goal:** Guarantee that loss, retry, duplication, and disconnect cannot strand a remote button or modifier.

**In scope:** Acknowledgements/retries for reliable transitions, action IDs, deduplication, heartbeat/current-state reconciliation, 500 ms timeout, disconnect/startup/shutdown release paths, and deterministic fault tests.

**Out of scope:** Long-held modifier UX, drag enabling, feature gestures, or changing BLE framing.

**Acceptance criteria:**

- Duplicate reliable actions are acknowledged but applied at most once.
- Missing acknowledgements retry only to a documented finite limit.
- At 500 ms without a valid heartbeat, every remotely held input is released.
- Disconnect, startup, and clean shutdown invoke idempotent release behavior.
- Fault tests cover loss at every press/release/ack boundary.

**Verification:** Run deterministic loss/duplicate/reorder tests against the mock event sink.

### - [ ] SAFE-004 — Add menu-bar status, Pause Remote Control, and Mac lifecycle guards

**Priority:** P0  
**Depends on:** SAFE-003  
**Unblocks:** PAD-001, KEY-001, LIFE-001

**Goal:** Make control state visible and give the local Mac user an immediate stop control.

**In scope:** Menu-bar connection/authentication/paused indicator, Pause/Resume action, lock, sleep, wake, logout/session-resign, app termination hooks, and mapping each event into SAFE-001.

**Out of scope:** Rich settings UI, auto-resume while unsafe, launch at login, or remote pause override.

**Acceptance criteria:**

- Pause immediately releases all held inputs and rejects new remote input.
- Lock, sleep, logout, and termination release inputs and enter a safe state.
- Resume cannot authorize input unless every safety precondition is true.
- Indicator states are derived from the same control state machine, not duplicated booleans.

**Verification:** Record observed state and mock/real sink output for each lifecycle transition.

---

## Phase 5 — Touchpad and keyboard features

### - [ ] PAD-001 — Deliver one-finger pointer movement and two-finger scrolling

**Priority:** P1  
**Depends on:** BLE-005, PAIR-005, SAFE-002, SAFE-004  
**Unblocks:** PAD-002, MOT-002

**Goal:** Add continuous trackpad motion through the existing pointer/scroll protocol and safety path.

**In scope:** Touch sampling/coalescing at display cadence, up-to-100 Hz relative pointer deltas, two-finger vertical scroll, local sensitivity, gesture cancellation, and simulated end-to-end tests.

**Out of scope:** Clicks, taps, dragging, horizontal scroll, inertial polish, or new protocol message types.

**Acceptance criteria:**

- One finger moves the cursor relatively; two-finger vertical motion scrolls.
- No pointer or scroll output is emitted after touch end/cancel or app backgrounding.
- Sensitivity changes remain local to the iPhone and output stays within protocol bounds.
- Finder and browser manual checks pass through authenticated BLE and safe injection.

**Verification:** Automated gesture-state tests plus a dated physical verification note.

### - [ ] PAD-002 — Add atomic left/right click and guarded drag

**Priority:** P1  
**Depends on:** PAD-001, SAFE-003  
**Unblocks:** LIFE-001, QA-001

**Goal:** Add discrete click gestures, then enable drag only after safety fault tests pass.

**In scope:** Single tap as atomic left click, two-finger tap as atomic right click, double-tap-and-hold drag state machine, acknowledgements/deduplication, cancellation, and a feature flag/default-off guard for drag until tests pass.

**Out of scope:** Arbitrary button mappings, long press menus, multi-button chords, or changing watchdog duration.

**Acceptance criteria:**

- Each tap produces one complete atomic click even with duplicate/retried packets.
- Ambiguous/cancelled gestures produce no stuck down state.
- Drag remains disabled until forced-disconnect mouse-down tests pass.
- Once enabled, touch/app/BLE cancellation releases the drag immediately.

**Verification:** Mock-sink fault tests and Finder/browser physical click/drag checks.

### - [ ] KEY-001 — Deliver bounded Unicode text entry

**Priority:** P1  
**Depends on:** PAIR-005, SAFE-002, SAFE-004  
**Unblocks:** KEY-002, AUD-003

**Goal:** Send ordinary Unicode text separately from physical key actions.

**In scope:** iPhone text-entry UI, bounded text payloads, submit/cancel behavior, safe Mac Unicode injection, empty/oversized handling, and privacy tests.

**Out of scope:** Clipboard sync, keylogging, text history, arbitrary key scripts, rich IME control, or hotkeys.

**Acceptance criteria:**

- Representative ASCII, accented, CJK, emoji, and composed Unicode text reaches TextEdit correctly or has a documented platform limitation.
- Text is not persisted or included in logs/metrics.
- Oversized input is split or rejected according to the documented protocol rule.
- Locked, paused, disconnected, or unauthenticated state rejects text.

**Verification:** Automated bounds/redaction tests plus a physical TextEdit matrix.

### - [ ] KEY-002 — Add the fixed atomic hotkey allowlist

**Priority:** P1  
**Depends on:** KEY-001, SAFE-003  
**Unblocks:** LIFE-001, QA-001

**Goal:** Support only the MVP shortcut set as named atomic actions with complete transitions.

**In scope:** Copy, Paste, Undo, Redo, Select All, Escape, Return, Tab, and arrow actions; explicit key/modifier transitions; US plus one non-US keyboard layout test; disconnect fault tests.

**Out of scope:** User-defined shortcuts, raw keycodes from the phone, long-held modifiers, macros, or application launching.

**Acceptance criteria:**

- The phone can request only protocol allowlist enum cases, not arbitrary combinations.
- Every action has a complete, deterministic press/release sequence.
- Unknown actions fail closed and do not post partial events.
- Forced disconnect at every transition point leaves no modifier held.

**Verification:** Exact mock-sink sequence tests and manual checks in TextEdit/Finder on two keyboard layouts.

---

## Phase 6 — Gyroscope air mouse

### - [x] MOT-001 — Implement and unit-test the pure motion-to-pointer filter

**Priority:** P1  
**Depends on:** PRO-001, FND-003  
**Unblocks:** MOT-002

**Goal:** Convert timestamped fused attitude/rotation samples into bounded relative pointer deltas without UI or Core Motion coupling.

**In scope:** Reference orientation, clutch reset semantics, dead zone, low-latency smoothing, nonlinear acceleration curve, sensitivity parameters, timestamp/rate handling, and recorded synthetic fixtures.

**Out of scope:** `CMMotionManager`, iPhone screens, BLE, absolute pointing, or double-integrated acceleration.

**Acceptance criteria:**

- Stationary/noise fixtures produce output below a documented drift threshold.
- Clutch reset makes the next accepted pose the neutral reference.
- Slow and fast rotation fixtures demonstrate precision and acceleration behavior.
- Invalid timestamps, sample gaps, and extreme values reset or clamp deterministically.

**Verification:** Plot-free numeric fixture assertions run in the normal test suite.

### - [ ] MOT-002 — Integrate Core Motion, clutch UI, calibration, and shared pointer output

**Implementation note (2026-09-02):** Phone clutch, Core Motion, shared
`motionPointerDelta` send, Mac pointer mapping, and a local speed slider are
wired. Leave this box unchecked until Gate E physical evidence is recorded.

**Priority:** P1  
**Depends on:** MOT-001, BLE-005, SIM-001, SAFE-004, PAD-001  
**Unblocks:** LIFE-001, QA-001

**Goal:** Deliver an end-to-end air-mouse mode that uses the same pointer messages and Mac safety path as touchpad mode.

**In scope:** `CMDeviceMotion` up to 100 Hz, hold-to-activate clutch, sample lifecycle, calibration/sensitivity controls, filtered output rate metrics, and presentation-distance target test.

**Out of scope:** Accelerometer double integration, background motion, absolute screen mapping, or a second Mac injection path.

**Acceptance criteria:**

- Releasing clutch immediately freezes output; re-engaging establishes a new neutral pose.
- Stationary phone shows no visible cursor drift under the documented test.
- A user can select approximately 32 px targets at normal presentation distance after calibration.
- Touchpad and air mouse emit the same pointer-delta protocol payload.

**Verification:** Save Gate E procedure, calibration values, sample/output rates, and results in `docs/verification/gate-e-air-mouse.md`.

---

## Phase 7 — Push-to-talk audio and transcription

### - [ ] AUD-001 — Capture bounded 16 kHz mono PCM with local push-to-talk

**Priority:** P1  
**Depends on:** BLE-005, PAIR-005, FND-003  
**Unblocks:** AUD-002

**Goal:** Produce correctly formatted audio chunks only while the iPhone user actively holds push-to-talk.

**In scope:** Microphone permission, AVAudioSession/capture configuration, conversion to signed 16-bit 16 kHz mono PCM, chunk sequencing/timestamps, level calculation, press/hold/release/cancel state, and foreground lifecycle.

**Out of scope:** Mac-triggered microphone activation, background recording, compression, transcription, or persistent phone recordings.

**Acceptance criteria:**

- No capture begins without a local active push-to-talk gesture.
- Release, cancel, interruption, route change, permission loss, and backgrounding stop capture.
- Produced chunks have continuous declared sample positions or an explicit measured gap.
- Raw audio bytes and derived speech content never enter logs.

**Verification:** Unit-test the capture state machine and inspect a short local test stream's format/levels.

### - [ ] AUD-002 — Transport PCM, expose health, and reconstruct a valid WAV on Mac

**Priority:** P1  
**Depends on:** AUD-001, BLE-004, OBS-001  
**Unblocks:** AUD-003, QA-001

**Goal:** Prove the deliberately demanding raw-PCM BLE path and preserve pointer responsiveness.

**In scope:** Audio chunk scheduling/backpressure, sequence/gap/late accounting, Mac reassembly, live level/health UI, bounded buffering, valid WAV header/finalization, five-minute run, and concurrent pointer latency measurement.

**Out of scope:** Opus/AAC unless Gate F fails and a later ticket is approved, transcription, automatic upload, or permanent audio retention policy beyond local test cleanup.

**Acceptance criteria:**

- A five-minute reconstructed WAV has 16 kHz mono 16-bit format and duration matching received samples/gaps.
- Missing, duplicate, and late chunks are measured and surfaced rather than concealed.
- Pointer p95 latency remains at most 50 ms during streaming or the gate is recorded failed.
- Buffering is bounded and disconnect/interruption finalizes or discards files deterministically.

**Verification:** Save aggregate results, WAV inspection command/output, and concurrent latency in `docs/verification/gate-f-audio.md` without committing the recording.

### - [ ] AUD-003 — Add the macOS Speech transcription adapter and optional safe insertion

**Priority:** P1  
**Depends on:** AUD-002, KEY-001  
**Unblocks:** LIFE-001, QA-002

**Goal:** Show a final transcript on Mac and optionally route it through the existing safe text-input boundary.

**In scope:** Speech framework adapter, permission/error states, transcription of completed/reconstructed audio, visible final text, explicit optional insert action, and test adapter.

**Out of scope:** Accuracy targets, diarization, wake word, continuous listening, cloud transcription service, or bypassing KEY-001/SAFE-001 for insertion.

**Acceptance criteria:**

- A spoken sentence produces visible final transcript text on the target Mac.
- Denied/unavailable Speech permission yields a clear non-crashing state.
- Transcript insertion is a local explicit action and uses the existing safe text path.
- Transcript content is not written to diagnostic logs.

**Verification:** Adapter unit tests plus one documented physical spoken-sentence run.

---

## Phase 8 — Lifecycle hardening and final decision

### - [ ] LIFE-001 — Harden reconnect, app lifecycle, sleep/wake, and trust revocation

**Priority:** P0  
**Depends on:** PAIR-004, SAFE-004, PAD-002, KEY-002, MOT-002, AUD-003  
**Unblocks:** QA-001

**Goal:** Make every expected platform transition converge on a documented safe state and permit valid recovery.

**In scope:** Previously trusted reconnect while both apps are active, Bluetooth off/on, iPhone foreground/background, Mac sleep/wake, lock/unlock, helper restart, clean shutdown, audio/motion interruption, and trust deletion on either side.

**Out of scope:** iPhone suspended/lock-screen control, Mac login/FileVault screens, launch at login, background BLE promises, or new features.

**Acceptance criteria:**

- A transition table names pre-state, event, immediate safe state, release action, reconnect eligibility, and expected UI.
- Every disconnecting/unsafe transition releases remote input and stops phone sensors/capture as applicable.
- Known trust reconnects without QR only after fresh authentication.
- Trust deletion on either side prevents reconnect until new pairing.

**Verification:** Automated state-machine coverage plus a completed physical transition matrix in `docs/verification/lifecycle-matrix.md`.

### - [ ] QA-001 — Build and run the repeatable fault-injection and coexistence matrix

**Priority:** P0  
**Depends on:** LIFE-001, OBS-001, SAFE-003, AUD-002  
**Unblocks:** QA-002

**Goal:** Produce trustworthy Gate D and cross-feature evidence under failures and radio contention.

**In scope:** 100 forced disconnects during mouse-down and modifier-down, packet loss/duplicate/reorder, heartbeat timeout, app termination, Bluetooth cycling, AirPods connected, heavy Wi-Fi traffic, audio plus pointer concurrency, and local metric capture.

**Out of scope:** Fixing failures in the same ticket, changing thresholds, or omitting failed trials.

**Acceptance criteria:**

- All 100 forced-disconnect trials produce zero stuck buttons/modifiers for Gate D to pass.
- Locked/sleeping/paused/quitting states reject remote input in observed tests.
- Each trial records scenario, seed where applicable, expected result, observed result, and aggregate metrics.
- Failures link to newly proposed remediation tickets; this ticket does not absorb fixes.

**Verification:** Commit only sanitized procedures/results to `docs/verification/gate-d-input-safety.md` and related aggregate files.

### - [ ] QA-002 — Publish the Gates A–F go/no-go report

**Priority:** P0  
**Depends on:** FND-003, BLE-005, PAIR-005, PAD-002, KEY-002, MOT-002, AUD-003, QA-001  
**Unblocks:** Product-MVP decision only

**Goal:** Decide whether to proceed, try audio compression, redesign the transport, or stop.

**In scope:** Link the exact evidence for Gates A–F, summarize device/software matrix, latency/stall/gap/reconnect/safety/motion/audio results, list deviations and unresolved risks, and state one explicit recommendation with the smallest justified next scope.

**Out of scope:** Implementing fixes, adding compression, starting product polish, App Store work, or declaring unmeasured assumptions as passes.

**Acceptance criteria:**

- Every gate is labeled `PASS`, `FAIL`, or `NOT RUN`; only measured criteria may pass.
- The report applies the source scope's decision rules without weakening thresholds.
- If raw PCM alone fails while control is reliable, compression is a proposed follow-up rather than silently added here.
- If input-state safety fails, the recommendation is to stop feature expansion and redesign it.
- Final recommendation is one of: proceed to product MVP, run a named bounded follow-up, redesign, or stop.

**Verification:** A reviewer can trace every conclusion to a committed sanitized result or clearly identified manual observation.

---

## Gate mapping

| Gate | Primary evidence ticket(s) |
|---|---|
| A — Toolchain and physical-device loop | FND-001 through FND-003 |
| B — BLE link | BLE-001 through BLE-005 |
| C — Pairing security | PAIR-001 through PAIR-005 |
| D — Input safety | SAFE-001 through SAFE-004, PAD-001, PAD-002, KEY-001, KEY-002, QA-001 |
| E — Air mouse | MOT-001, MOT-002 |
| F — Voice path | AUD-001 through AUD-003 |
| Final decision | LIFE-001, QA-001, QA-002 |

## Deferred follow-up tickets (create only if a gate justifies them)

Do not implement these as part of the current backlog:

- PCM compression experiment using Opus or AAC if and only if raw PCM fails while control remains reliable.
- Production distribution, notarization, App Store/TestFlight, accounts, subscriptions, and onboarding polish.
- Android/Windows clients, Wi-Fi/hybrid transport, cloud relay, generic HID, background/lock-screen control, clipboard/files/screen sharing, and automation/macros.
