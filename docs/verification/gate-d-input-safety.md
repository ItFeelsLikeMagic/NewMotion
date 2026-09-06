# Gate D — Input-safety verification

Status: **NOT RUN on physical hardware**. The policy, release, watchdog, retry,
and lifecycle paths have automated coverage, but a real Accessibility event
posting run and the required 100 forced-disconnect trials have not been
completed. Simulator and mock-sink results are not a physical Gate D pass.

## Automated evidence

The 2026-09-02 scripted run passed 14 macOS tests, including eight safety and
lifecycle tests plus two framed-input integration tests. The tests prove that
commands are denied until every precondition is true, held buttons/modifiers
are released on unsafe transitions, duplicates are applied at most once, the
500 ms watchdog releases state, retry queues are bounded, and disconnect
cleanup reaches the mock sink. They do not prove that Core Graphics can post
events under a user's Accessibility setting.

Command:

```sh
NEWMOTION_RUN_IOS_TESTS=1 \
NEWMOTION_DERIVED_DATA=/tmp/NewMotionGateD \
./scripts/test.sh
```

## Physical procedure

Prerequisites are a signed Mac build, a foreground paired iPhone, and
Accessibility permission granted to the Mac app. Use only the mock/sanitized
aggregate fields below; do not record typed text, key material, or payloads.

1. Run 100 trials with a mouse-down held, forcing a BLE disconnect at each
   press/heartbeat/retry boundary. Repeat with each allowlisted modifier.
2. For every trial record whether exactly one mouse-up/key-up was observed,
   whether the watchdog fired when expected, and whether any retry was
   exhausted.
3. Repeat representative trials while paused, locked, asleep, logged out,
   quitting, and with Accessibility revoked. Each must reject new input and
   leave no held state.
4. Run once with AirPods connected and once with heavy local Wi-Fi traffic to
   expose coexistence regressions. Preserve failures and link remediation
   tickets; do not omit failed trials.

## Result template

### Run YYYY-MM-DD HH:MM TZ

- iPhone model / iOS build: `TBD`
- Mac model / macOS build: `TBD`
- Build identifier: `TBD`
- Trial count: `TBD` (required: 100 mouse-down and 100 modifier-down)
- Stuck buttons: `TBD`
- Stuck modifiers: `TBD`
- Watchdog releases / unexpected releases: `TBD / TBD`
- Unsafe-state rejection checks: `TBD`
- AirPods / Wi-Fi coexistence: `TBD`
- Result: `PASS` / `FAIL` / `BLOCKED`
- Sanitized evidence path: `TBD`
- Notes/remediation tickets: `TBD`

The signed app/device loop is available, but the blocker is the absence of a
completed Accessibility event-posting run and the required forced-disconnect
trials. Automated evidence remains useful regression coverage but does not
change this status.
