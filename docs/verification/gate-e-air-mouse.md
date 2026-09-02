# Gate E — Air-mouse verification

Status: **NOT RUN on physical hardware**. The pure quaternion filter, clutch
reset, bounds, and Core Motion adapter are implemented and unit-tested; no
target-device calibration, drift, or presentation-distance measurement has
been recorded.

## Automated evidence

The iOS suite passed 15 tests in the 2026-09-02 scripted run, including the
motion clutch/reference test and the trackpad/audio integration checks. The
motion test uses a deterministic provider and verifies that output stops when
the clutch is released. It cannot measure sensor noise, user calibration, or a
32 px target on a real display.

## Physical procedure

1. Pair the foreground iPhone with the Mac and confirm the authenticated input
   path is active.
2. Record the filter sensitivity, dead zone, smoothing, and sample/output
   rates. Hold the air-mouse clutch for a stationary 60-second drift run.
3. Release the clutch, change the phone orientation, and re-engage it. Verify
   the first accepted pose becomes the new neutral reference and that no
   output is produced while released.
4. At normal presentation distance, select approximately 32 px targets after
   calibration. Record misses and any visible drift without recording screen
   content.

## Result template

### Run YYYY-MM-DD HH:MM TZ

- iPhone model / iOS build: `TBD`
- Mac model / macOS build: `TBD`
- Build identifier: `TBD`
- Filter configuration: `TBD`
- Clutch-held duration: `TBD`
- Motion sample rate / output rate: `TBD / TBD Hz`
- Stationary drift: `TBD px/min` (documented threshold: `TBD`)
- 32 px target success: `TBD / TBD`
- Release/re-engage neutral reset: `PASS` / `FAIL`
- Result: `PASS` / `FAIL` / `BLOCKED`
- Sanitized evidence path: `TBD`
- Notes: `TBD`

Do not claim Gate E from simulator output alone. The signed app/device loop is
available; the remaining blocker is the missing authenticated physical
calibration, drift, and target-selection run.
