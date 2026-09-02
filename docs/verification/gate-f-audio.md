# Gate F — Voice-path verification

Status: **NOT RUN on physical hardware**. Push-to-talk gating, 16 kHz mono
PCM16 chunking, bounded reassembly, gap accounting, and explicit transcript
insertion have deterministic tests, but no five-minute physical WAV or
concurrent pointer-latency result exists.

## Automated evidence

The 2026-09-02 scripted run passed 15 iOS tests and 14 macOS tests. Coverage
includes local-press-only capture, stop-on-release, format/bounds checks,
audio payload framing, missing/duplicate/late chunk accounting, and the
explicit transcript insertion boundary. No raw audio, transcript, or recording
is stored in the repository.

## Physical procedure

1. On the foreground iPhone, grant microphone permission and hold Push to
   Talk for five minutes. Release, cancel, background, interrupt, and change
   the route in separate short runs; each must stop capture.
2. On the Mac, reconstruct the received samples into a temporary WAV and
   inspect only its format, duration, gap count, and aggregate health.
3. During the five-minute run, generate synthetic pointer motion and measure
   pointer p95 latency. The raw-PCM path must not conceal gaps or starve
   control traffic.
4. Delete the temporary recording after inspection. Do not commit it or place
   bytes in logs.

## Result template

### Run YYYY-MM-DD HH:MM TZ

- iPhone model / iOS build: `TBD`
- Mac model / macOS build: `TBD`
- Build identifier: `TBD`
- Capture duration: `TBD` (required: 5 minutes)
- WAV format: `TBD` (required: 16,000 Hz, mono, signed 16-bit PCM)
- Received samples / declared duration: `TBD / TBD s`
- Missing / duplicate / late chunks: `TBD / TBD / TBD`
- Concurrent pointer p95 latency: `TBD ms` (limit: 50 ms)
- Interruption/route/background stop behavior: `TBD`
- Result: `PASS` / `FAIL` / `BLOCKED`
- Sanitized evidence path: `TBD`
- Notes/remediation tickets: `TBD`

The signed app/device loop is available; the remaining blocker is the lack of a
completed microphone/BLE run. If raw PCM fails while control remains reliable,
record that failure and propose compression separately; do not add compression
in this gate document.
