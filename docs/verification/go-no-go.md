# Gates A–F go/no-go report

Status: **BLOCKED — Gate A install/launch pass, device diagnostics blocked; Gates B–F not run** (verdicts from 2026-09-02, notes refreshed 2026-09-03). This report is intentionally conservative: automated tests are recorded as evidence, but a gate is not marked PASS without its measured hardware criteria.

## Gate status

| Gate | Status | Evidence / blocker |
| --- | --- | --- |
| A — toolchain and physical-device loop | BLOCKED | Signed target-specific install and launch pass; app process remains present. `logs-phone.sh` is still blocked by Xcode 27 `DiagnoseError error 0`, so the complete gate cannot pass. The in-app `IPhoneDebugLog` pulled by `debug-phone.sh` substitutes for app logs but is not sysdiagnose. See [`gate-a-toolchain.md`](./gate-a-toolchain.md). |
| B — BLE link | NOT RUN | Deterministic framing/transport tests pass; the Mac discovered and connected to the phone in-app once (2026-09-02); no 30-minute 100 Hz hardware soak or Bluetooth off/on recovery result. See [`gate-b-ble.md`](./gate-b-ble.md). |
| C — pairing security | NOT RUN | Crypto, token, trust, and scanner tests pass; one owner-observed QR pair on 2026-09-02, then the phone camera went black until a phone restart on 2026-09-03 (see `docs/postmortem_camera_black_preview.md`); no physical scan/reconnect/revoke matrix or complete redaction run. See [`gate-c-pairing.md`](./gate-c-pairing.md). |
| D — input safety | NOT RUN | Mock-sink policy/watchdog/integration tests pass; no Accessibility event-posting run or 100+100 forced-disconnect trials. See [`gate-d-input-safety.md`](./gate-d-input-safety.md). |
| E — air mouse | NOT RUN | Deterministic motion filter/clutch test passes; no drift/calibration/32 px target measurement. See [`gate-e-air-mouse.md`](./gate-e-air-mouse.md). |
| F — voice path | NOT RUN | Press gating, cancel, boost parsing and merging, sentence splitting, and the `vocabulary`/`spokenText` bounds all pass in tests, and the path is in daily use. Transcription runs on the iPhone, so no audio crosses and there is nothing to reassemble. No timed run against the criteria. See [`gate-f-voice.md`](./gate-f-voice.md). |

## Automated verification snapshot

The latest scripted run used the generated fallback Xcode project and signing
disabled:

```sh
NEWMOTION_RUN_IOS_TESTS=1 \
NEWMOTION_DERIVED_DATA=/tmp/NewMotionTests \
./scripts/test.sh
```

As of 2026-09-03 it passes 28 shared tests, 29 macOS tests, and 42 iOS simulator tests. A
strict Swift 6 concurrency type-check, the five-target build, and the
deterministic 2,000-input protocol corpus also passed.
These results establish a repeatable regression baseline; they do not replace
the physical measurements listed above.

## Recommendation

**Run a named bounded follow-up before proceeding to a product MVP:** retry
device diagnostics with a compatible Xcode/device-support combination, run the
manual hardware loop in `docs/status.md` section 5 (pair, ping, pad, air mouse,
push to talk, relaunch reconnect), then execute Gates B–F in order and fill the
sanitized result blocks. Do not expand
feature scope, add compression, or claim a gate pass until the corresponding
measured criteria are present. If a gate fails, retain the failure and create
the smallest remediation ticket justified by its evidence.
