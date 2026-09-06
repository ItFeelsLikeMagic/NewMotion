# Gate A toolchain verification

This note records the foundation verification performed on 2026-09-02 (Asia/Shanghai) with Xcode 27.0 beta build `27A5252f`, Swift 6.4, an Apple-silicon MacBook Pro (M1 Max) on macOS 27.0, and an attached iPhone 15 Pro Max on iOS 27.0 build `24A5380h`. No Apple ID, team ID, UDID, key, or signing artifact is recorded here.

## CLI checks

| Command | Result | Evidence |
| --- | --- | --- |
| `./scripts/generate.sh` | PASS (exit 0) | XcodeGen was absent; deterministic `scripts/generate_fallback.py` generated `NewMotion.xcodeproj`. |
| `xcodebuild -project NewMotion.xcodeproj -list` | PASS (exit 0) | Six targets are listed: shared framework, two apps, and three unit-test bundles. |
| `xcodebuild ... -scheme NewMotionShared -sdk macosx ... build` | PASS (exit 0) | Shared framework compiled with the macOS 15.0 deployment target. |
| `xcodebuild test ... -scheme NewMotionSharedTests -destination 'platform=macOS' ...` | PASS (exit 0) | 23 shared protocol/transport/observability/BLE/pairing/integration/fuzz tests passed in the latest scripted run. |
| `NEWMOTION_DERIVED_DATA=/tmp/NewMotionFinalBuild3 ./scripts/build.sh` | PASS (exit 0) | Builds both app targets and all three test bundles; each reported `BUILD SUCCEEDED`. |
| `./scripts/test.sh` | PASS (exit 0) with iOS enabled | Latest run passed shared 23/23, macOS 14/14, and iOS simulator 15/15; the script selects an available iPhone simulator dynamically. |
| `NEWMOTION_DERIVED_DATA=/tmp/NewMotionFinalBuildAfterRunpath ./scripts/build.sh` | PASS (exit 0) | Regression after the embedded-framework runpath fix; all five build targets reported `BUILD SUCCEEDED`. |
| `NEWMOTION_RUN_IOS_TESTS=1 NEWMOTION_DERIVED_DATA=/tmp/NewMotionFinalTestsAfterRunpath ./scripts/test.sh` | PASS (exit 0) | Regression after the runpath fix: shared 23/23, macOS 14/14, and iOS simulator 15/15. |
| `NEWMOTION_RUN_IOS_TESTS=1 NEWMOTION_DERIVED_DATA=/tmp/NewMotionPairingStorageFixAllTests ./scripts/test.sh` | PASS (exit 0) | Latest regression after the macOS Keychain enumeration fix: shared 24/24, macOS 18/18, and iOS simulator 17/17. |
| `NEWMOTION_DERIVED_DATA=/tmp/NewMotionPairingStorageFixMacTests2 ./scripts/test.sh` | PASS (exit 0) | Latest focused regression after the empty-Keychain coordinator startup check: shared 24/24 and macOS 19/19; iOS execution was intentionally skipped. |
| `open -n NewMotion.app` plus `NEWMOTION_LOG_WINDOW=1m ./scripts/logs-mac.sh` | PASS (exit 0) | Fresh macOS menu-bar app launched; the read-only unified-log probe returned process-scoped output. |

The generated project and local `DerivedData` remain ignored by Git. The fallback generator discovers new Swift files below the shared/app/test roots so later feature tickets do not need to edit generated project state.

## Physical-device boundary

After the owner enabled Developer Mode and restarted, the latest read-only
`xcrun devicectl list devices` probe sees the target phone as
**available (paired)**. A second physical phone is unavailable. `device info
details` reports Developer Mode Enabled and `device info ddiServices` reports
compatible, usable DDI content while the phone is unlocked.

The owner signed into Xcode, which created a local Apple Development identity
and development profile. A signed build targeted explicitly at the supplied
phone and `devicectl device install app` both exited 0. The repeatable
`install-phone.sh` signed workflow also exited 0; identifiers and signing
values remain local-only.

`launch-phone.sh` exited 0, and a process query three seconds later found the
NewMotion app still running on the phone. A console launch produced no
dynamic-loader error. Before the final pass, launch had exposed two packaging
issues: the shared framework's install name was absolute, and the app lacked an
`@executable_path/Frameworks` runpath. The project and fallback generator now
set the `@rpath` install name and embedded-framework runpaths; `codesign
--verify --deep --strict` passes.

`logs-phone.sh` was exercised with the app running and the phone unlocked, but
Xcode 27 returned `CoreDeviceCLISupport.DiagnoseError error 0` and produced no
diagnostic archive. This leaves log collection **BLOCKED by the toolchain**;
it does not negate the signed install/launch evidence.

Required one-time GUI steps are:

1. Enable Developer Mode on the iPhone and confirm its reboot.
2. Approve “Trust This Computer” if prompted.
3. Select a local development team/signing identity in Xcode. This has been completed for the current run; keep all signing values outside Git.
4. Export `IPHONE_UDID` (or pass `--udid`) and run `install-phone.sh`, `launch-phone.sh`, and `logs-phone.sh` once. Record model, OS, timestamp, duration, and observed result in this file after that run.

The current exact boundary is **BLOCKED — owner: project owner/toolchain maintainer; blocker: Xcode 27 sysdiagnose (`DiagnoseError error 0`)**. Signed install and launch are verified; a future worker should retry device diagnostics with a newer Xcode/device support bundle or capture an equivalent redacted console aggregate. The command scripts still fail before invoking Apple tooling when the required device identifier is absent.

## Bounded run record

### 2026-09-02 — signed install/launch and log probe

- iPhone model / iOS build: iPhone 15 Pro Max / iOS 27.0 (build recorded in the pinned matrix)
- Mac model / macOS build: Apple-silicon MacBook Pro / macOS 27.0
- `device info ddiServices`: PASS (`contentIsCompatible=true`, `isUsable=true` while unlocked)
- Signed physical-SDK build: PASS (target-specific destination, local Apple Development identity)
- `install-phone.sh`: PASS (exit 0; bundle ID `com.example.newmotion.ios`)
- `launch-phone.sh`: PASS (exit 0; process remained present after 3 seconds)
- `logs-phone.sh`: BLOCKED (exit 1; `CoreDeviceCLISupport.DiagnoseError error 0`; no archive)
- Result: **BLOCKED for complete Gate A**; install/launch subchecks PASS
- Privacy: no Apple ID, team ID, UDID, profile contents, or diagnostic payloads are recorded.
