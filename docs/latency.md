# Latency

What the remote costs, where the time goes, and how to measure it again. Numbers
here are for dliao's iPhone 15 Pro Max to an M1 Max MacBook Pro over BLE.

## The chain, press to effect

1. **Touch to send.** SwiftUI gesture, encrypt, fragment. Under a millisecond of
   work, plus up to one display frame (8 ms at 120 Hz) before the gesture fires.
2. **Bluetooth hop.** The phone is the peripheral and sends notifications, so
   nothing waits for an acknowledgement, but the packet waits for the next
   connection slot. This is the part the phone measures, and as of the first
   measurement it is the biggest one.
3. **Mac receive.** Reassemble, decrypt, decode, dispatch on the main actor.
   Sub-millisecond.
4. **Key posting.** Paced on a private serial queue, never on the main thread.
   This is the part the Mac measures.
5. **The system reacts.** The Dock's switcher panel fades in over roughly
   100 ms. Not measurable from inside either app; the selection underneath is
   already correct before the fade finishes.

## Fixed costs we chose

Key events cannot be posted in one burst. A flags change needs to settle before
the key it modifies, or the Dock sees a bare Tab and never opens the switcher.
`CGEventInputSink` spaces them:

| Gap | Value | Applies to |
| --- | --- | --- |
| `modifierSettle` | 25 ms | after a Command or Shift flags change |
| `keyGap` | 10 ms | between ordinary key events |

That gives, from the moment a message lands on the Mac:

| Action | Key events | Mac cost |
| --- | --- | --- |
| App switcher begin | Command down, Tab down, Tab up | 45 ms |
| One slide step | Tab down, Tab up | 20 ms |
| Commit | Command up | 10 ms |
| Escape or Return | key down, key up | 20 ms |

Slide steps queue behind each other on the posting queue, so a fast slide across
six apps is about 120 ms of key events still going out after the finger stops.

These were 40 ms flat until 2026-09-03, which cost 120 ms to open the switcher
and 80 ms per slide step.

## Cursor path

Cursor lag showed up as backpressure: a move landed late and then caught up
after the finger stopped. The cause was packet cost, not processing. One cursor
move spent about 282 bytes on the radio (206-byte JSON envelope, 60 bytes of
AEAD, 16-byte BLE header) to carry four bytes of movement, and the phone threw a
move away outright whenever Core Bluetooth had no room for it.

Changed 2026-09-03:

- `PointerStreamFrame` (`Shared/Protocol/PointerStreamFrame.swift`) carries a
  delta in 11 bytes of plaintext instead of 206. It is encrypted as message type
  `pointerDelta` and recognised by its `PRP1` magic, and several deltas ride in
  one frame. About 87 wire bytes against 282.
- Sum on busy, not drop. `flushCursorStream` in `iPhone/PhoneRemoteApp.swift`
  keeps the accumulated travel when the radio refuses a single-frame message and
  retries on the transport's `onReadyToSend` callback. A message that needs more
  than one fragment still queues whole, and a click forces a queued flush so it
  cannot overtake the travel before it.
- One pacer. `TrackpadGestureEngine` no longer rate limits;
  `displayCadenceLimitHz` is gone and `TrackpadOutputCoalescer` (16 ms) is the
  only pacer on the path.
- The air mouse rides the same frame and the same retry.
  `SharedMotionProtocolAdapter` is deleted. The `motionPointerDelta` protocol
  case stays for the Mac's decoder.
- The air mouse shares the pacer too. Core Motion samples hand off to the main
  queue as they arrive (`DeltaCoalescer.motionPointer()` no longer paces) and
  join `TrackpadOutputCoalescer.handlePointer`, so cursor travel updates at
  about 60 Hz from either sensor instead of 25 Hz from the air mouse, and two
  sensors moving one cursor cannot each spend a full packet budget.
- `CursorTravel` (`iPhone/Trackpad/CursorTravel.swift`) keeps the sub-point
  remainder between packets, and any travel past what one frame carries. Whole
  points go out, the fraction waits. Rounding each packet on its own discarded
  up to half a point every time, so slow air-mouse aiming under roughly 12
  points a second moved the cursor not at all: the "low resolution" feel.
- Air-mouse gain is a bounded curve, not a straight line. Output is scaled by
  `(speed / accelerationReference) ^ (accelerationExponent - 1)`, clamped to
  0.6x and 1.8x, with the exponent at 1.25 and the reference at 0.0052 rad per
  sample (about 30 deg/s at 100 Hz). Feel at that speed is unchanged, a slow
  wrist turn aims finer, a sweep covers more screen per packet. The gain uses
  the two-axis magnitude, so a diagonal turn is not faster than a straight one.
- Cursor traffic is off the debug snapshot. Pointer, scroll, and motion deltas
  bump a `cursorEvents` counter that republishes at 2 Hz instead of assigning
  `lastApplicationMessage`, whose every write rebuilt the whole
  `MacDebugSnapshot` and invalidated the SwiftUI surface. `debug-mac.sh` reads
  the counter to confirm input is arriving.
- The Mac no longer hops each received frame through `Task { @MainActor }`. Core
  Bluetooth already calls back on the main queue, so the hop only queued packets
  behind whatever the main actor was doing. Same fix as the phone's motion sink.

Physical feel after these changes is not measured yet.

## How to measure

**Bluetooth round trip.** Settings tab, tap Ping Mac. It sends five pings 250 ms
apart and reports average, best, and how many came back, under Link round trip.
Pongs carry no identifier and are matched to sends in order; the spacing is far
wider than the round trip, which keeps that honest. One-way is roughly half.
Samples also land in the phone debug log as `ping_rtt`.

**Mac key posting.** Use a hotkey, then read `keyPostMs` from
`./scripts/debug-mac.sh`. It is the wall time for the last paced burst, from
hand-off to its final event reaching the window server.

**What is not measured.** The Dock's own reaction, and the touch-to-send step.
Neither app can see them.

## Measured

2026-09-03, phone on the desk beside the Mac, both apps foreground.

| What | Value |
| --- | --- |
| Bluetooth round trip | 53, 58, 68, 77, 85 ms. Average 68, best 53. |
| One way, inferred | roughly 30 ms |
| Mac key posting, commit queued behind a begin | 49 ms measured |
| Mac key posting, idle queue | 45 ms begin, 20 ms step, 10 ms commit, from the constants above |

A quick tap of the switcher button, no slide, therefore costs roughly
**115 to 135 ms** from press to the Mac switching apps: one hop out, the begin
burst, one hop out again on release, then the commit.

The round trip includes the Mac decoding the ping and encoding a pong, so half
of it slightly overstates the one-way input hop. It is the honest ceiling.

Sliding does not back up in practice. In the recorded slide, steps left the
phone about 130 to 640 ms apart, far slower than the 20 ms each costs to post,
so the queue stayed empty and the highlight tracked the finger.

The Bluetooth hop is now the largest single cost, and it is not ours to tune
directly; macOS and iOS negotiate the connection interval.

## Future experiments, not started

Lossless:

1. Cache the cursor position on the Mac. `CGEventInputSink` asks the window
   server for the current location on every move
   (`CGEvent(source: nil)?.location`). Not recommended: it saves tens of
   microseconds per event, and a cached point stops matching reality at a screen
   edge, where the window server clamps the real cursor while our copy keeps
   travelling. Reversing off an edge would then lag by however far the copy had
   run past it. Only worth revisiting with proper display-bounds clamping.
2. Shrink the AEAD header for the fast path. Reviewed below: 47 wire bytes
   against 87, but it needs per-direction session subkeys first. Not recommended
   before the lossy items.

Lossy:

3. Cap how far ahead the phone may run. Hand Core Bluetooth at most one cursor
   packet and hold the sum for everything else, so the radio can never build a
   backlog to replay.
4. Merge the Mac's backlog into one cursor move per screen frame. The cursor
   lands where the finger is now instead of tracing the old path.
5. Pointer acceleration curve for the trackpad. The air mouse has one; trackpad
   gain is still linear, so a fast flick needs as many packets as a slow drag.
6. Deadline drop. Discard a cursor delta older than about 60 ms once a newer one
   exists. Only meaningful together with 3 or 4.

## AEAD header review, 2026-09-03

Reviewed shrinking the 60 bytes of crypto framing that now dominate an 87-byte
cursor packet. Verdict: possible at 47 bytes, but it needs a change to session
key derivation first, so it is parked behind the cheaper lossy work.

- Leaving the 16-byte session ID off the wire is safe. It is already checked
  against local state and stays in the authenticated header.
- Deriving the nonce from a counter is only safe once per-direction subkeys
  exist. Today both sides derive the same key and both start their counter at
  zero, so a counter nonce would guarantee a repeat across directions. A repeat
  under ChaCha20-Poly1305 leaks the authentication key and lets an attacker forge
  input into a Mac that holds Accessibility permission.
- A 2-byte wire counter is safe if the full 64-bit counter still feeds the nonce
  and the header, the value resolves as nearest candidate to the high-water
  mark, and state commits only after the tag verifies.
- Dropping magic, version, and length is safe, but a one-byte frame
  discriminator has to replace the magic so the two frame shapes stay
  distinguishable.
- Truncating the 16-byte tag is not worth it. CryptoKit will not do it, so it
  means hand-writing the AEAD to save eight bytes on an input-injection channel.

Layout if it is ever done: 1 discriminator, 1 role/epoch, 2 counter, with the
authenticated header rebuilt from local state and the nonce built from the role
byte, a session salt, and the 64-bit counter.

The review also turned up security bugs unrelated to latency. One is fixed (the
sliding replay window, see `docs/worker_learnings.md`); the rest are recorded
under "Known problems and traps" in `docs/status.md`.
