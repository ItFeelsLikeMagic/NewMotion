# Gate B — BLE link verification

Status: **not run on physical hardware** (implementation and deterministic
unit-test coverage are present; the target is paired with Developer Mode
enabled and the signed app now launches, but the 30-minute radio run is still
pending).

## Automated evidence

Run from the repository root after the Xcode project includes
`Shared/Crypto` and the transport tests:

```sh
./scripts/generate.sh
./scripts/test.sh
```

The focused tests must cover the 20-byte minimum ATT value length, at least
one larger negotiated value length, exact-boundary and one-byte-over envelopes,
ordered fragment reassembly, loss/duplicate/reorder behavior, bounded queues,
and disconnect cleanup. Record command exit codes and the test bundle in the
implementation checkpoint; do not record payload contents.

## Physical procedure

Fill one dated result block for each run. The phone app must be foregrounded;
the Mac central must scan by the custom service UUID without opening
Bluetooth Settings.

1. Build/install both apps using the documented signing override.
2. Start the Mac central and the iPhone peripheral; record the state
   transition through service discovery and notification subscription.
3. Send synthetic pointer-delta envelopes at 100 Hz for 30 minutes. The
   generator must use sequence numbers and an injected/monotonic clock; it
   must not contain real input content.
4. Record round-trip latency p50/p95/p99, sent/received/dropped/backpressured
   counts, sequence gaps, duplicates, retries, and the longest stall.
5. Toggle Bluetooth off and on, then verify both sides enter a safe
   disconnected state and reconnect only after the normal discovery/subscription
   path. Record recovery time and any dropped frames.

## Result template

### Run YYYY-MM-DD HH:MM TZ

- iPhone model / iOS build: `TBD`
- Mac model / macOS build: `TBD`
- App/build identifier (no signing secrets): `TBD`
- Start/end timestamps: `TBD`
- Duration: `TBD` (required: 30 minutes)
- Negotiated write/notify value length(s): `TBD`
- Sent / delivered / dropped / backpressured: `TBD / TBD / TBD / TBD`
- Sequence gaps / duplicates / retries: `TBD / TBD / TBD`
- Round-trip latency p50 / p95 / p99: `TBD / TBD / TBD ms`
- Longest unexplained stall: `TBD ms` (Gate B limit: 250 ms)
- Bluetooth off/on recovery: `TBD`
- Result: `PASS` / `FAIL` / `BLOCKED`
- Evidence/log path (local aggregate only): `TBD`
- Notes: `TBD`

Do not fill this block with device identifiers, QR material, keys, typed text,
audio, or packet payloads. If the radio gate fails, retain the failure and
metrics rather than replacing them with a simulator result.

The current physical prerequisite is an authenticated Mac/iPhone session with
the signed app foregrounded. The install/launch prerequisite is now satisfied;
the BLE soak and Bluetooth recovery measurements remain outstanding.
