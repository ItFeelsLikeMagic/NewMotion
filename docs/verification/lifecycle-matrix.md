# Lifecycle and recovery verification

This matrix is the hardware-run record for LIFE-001. Automated state-machine
coverage lives in the macOS and iOS safety-feature tests; the rows below must
be completed on the target Mac/iPhone pair before claiming the physical gate.

## Procedure

1. Pair once through the QR flow and confirm both apps show an authenticated,
   active connection.
2. Hold the left mouse button, a modifier, the air-mouse clutch, and push to
   talk independently while exercising the transition in each row.
3. Record whether the input sink received exactly one release for every held
   input, whether sensors/audio stopped, and whether reconnect required a new
   QR scan.
4. For trusted reconnect rows, confirm the BLE layer performs a fresh
   authenticated handshake; a BLE identifier or display name alone is not
   sufficient.

## Matrix

| Pre-state | Event | Immediate safe state | Required release/stop | Reconnect eligibility | Observed result |
|---|---|---|---|---|---|
| Authenticated/active | iPhone backgrounds | Phone inactive/disconnected | release input; stop motion/audio; disconnect BLE | after foreground + fresh auth | TBD: device/OS/date |
| Authenticated/active | iPhone foregrounds | Phone foreground | no stale sensor/capture state | trusted device only, fresh auth | TBD: device/OS/date |
| Authenticated/active | Bluetooth off | Disconnected | release input; stop motion/audio | after Bluetooth on and fresh auth | TBD: device/OS/date |
| Disconnected | Bluetooth on | Reconnect eligible | none held | trusted device only | TBD: device/OS/date |
| Authenticated/active | Mac locks | Mac locked/disconnected | release buttons/modifiers | after unlock + fresh auth | TBD: device/OS/date |
| Authenticated/active | Mac sleeps | Mac asleep/disconnected | release buttons/modifiers; stop capture | after wake + fresh auth | TBD: device/OS/date |
| Locked/asleep | Mac wakes/unlocks | Safe disconnected | no stale held state | trusted device only | TBD: device/OS/date |
| Authenticated/active | Mac helper restarts | Startup/disconnected | release all; no startup-held state | trusted device only | TBD: device/OS/date |
| Authenticated/active | Local Pause | Paused | release buttons/modifiers | resume only when safe | TBD: device/OS/date |
| Authenticated/active | Trust deleted on iPhone | Disconnected/untrusted | release input; stop motion/audio | no reconnect until QR | TBD: device/OS/date |
| Authenticated/active | Trust deleted on Mac | Disconnected/untrusted | release input; stop motion/audio | no reconnect until QR | TBD: device/OS/date |
| Capturing/motion active | Audio interruption/route change | Capture stopped | stop audio; motion remains clutch-gated | no remote microphone activation | TBD: device/OS/date |
| Capturing/motion active | App termination | Inactive/disconnected | release input; stop motion/audio | no automatic resume | TBD: device/OS/date |

## Record format

For every completed row record the iPhone model, iOS build, Mac model, macOS
build, date/time with timezone, run duration, event timing, release count,
reconnect result, and any observed error code. Do not record typed text,
transcripts, QR material, keys, or audio bytes.
