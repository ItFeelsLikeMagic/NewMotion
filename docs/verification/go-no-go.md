# Gates A–F go/no-go report

Status: **BLOCKED — Gate A install/launch pass, device diagnostics blocked; Gates B–F not run** (2026-09-02, Asia/Shanghai). This report is intentionally conservative: automated tests are recorded as evidence, but a gate is not marked PASS without its measured hardware criteria.

## Gate status

| Gate | Status | Evidence / blocker |
| --- | --- | --- |
| A — toolchain and physical-device loop | BLOCKED | Signed target-specific install and launch pass; app process remains present. `logs-phone.sh` is blocked by Xcode 27 `DiagnoseError error 0`, so the complete gate cannot pass. See [`gate-a-toolchain.md`](./gate-a-toolchain.md). |
| B — BLE link | NOT RUN | Deterministic framing/transport tests pass; signed app is available, but no 30-minute 100 Hz hardware soak or Bluetooth off/on recovery result. See [`gate-b-ble.md`](./gate-b-ble.md). |
| C — pairing security | NOT RUN | Crypto, token, trust, and scanner tests pass; no physical QR scan/reconnect/revoke matrix or complete redaction run. See [`gate-c-pairing.md`](./gate-c-pairing.md). |
| D — input safety | NOT RUN | Mock-sink policy/watchdog/integration tests pass; no Accessibility event-posting run or 100+100 forced-disconnect trials. See [`gate-d-input-safety.md`](./gate-d-input-safety.md). |
| E — air mouse | NOT RUN | Deterministic motion filter/clutch test passes; no drift/calibration/32 px target measurement. See [`gate-e-air-mouse.md`](./gate-e-air-mouse.md). |
| F — voice path | NOT RUN | PCM gating/reassembly/integration tests pass; no five-minute physical WAV or concurrent pointer-latency measurement. See [`gate-f-audio.md`](./gate-f-audio.md). |

## Automated verification snapshot

The latest scripted run used the generated fallback Xcode project and signing
disabled:

```sh
PHONE_REMOTE_RUN_IOS_TESTS=1 \
PHONE_REMOTE_DERIVED_DATA=/tmp/PhoneRemoteFinalTestsAfterRunpath \
./scripts/test.sh
```

It passed 23 shared tests, 14 macOS tests, and 15 iOS simulator tests. A
strict Swift 6 concurrency type-check, the five-target build, and the
deterministic 2,000-input protocol corpus also passed.
These results establish a repeatable regression baseline; they do not replace
the physical measurements listed above.

## Recommendation

**Run a named bounded follow-up before proceeding to a product MVP:** retry
device diagnostics with a compatible Xcode/device-support combination, then
execute Gates B–F in order and fill the sanitized result blocks. Do not expand
feature scope, add compression, or claim a gate pass until the corresponding
measured criteria are present. If a gate fails, retain the failure and create
the smallest remediation ticket justified by its evidence.
