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
| `modifierSettle` | 0 ms | after a Command or Shift flags change |
| `keyGap` | 10 ms | between ordinary key events |
| `keyRunGap` | 0 ms | inside one `hotkeyRun`, a single key repeated |

A run of one repeated key is the exception to the first sentence, because there
is nothing in it to distinguish: the presses are identical by definition. So a
held delete key's word notch goes out as one `hotkeyRun` command with no
spacing inside it, and a five-letter word costs about a millisecond instead of
about 100 ms. Measured, not assumed; see below.

A gap is measured from the last event actually posted, not from the start of the
burst, so a queue that has been idle waits for nothing on its first event. That
splits every figure below in two. From the moment a message lands on the Mac:

| Action | Key events | Idle queue | Queued behind another burst |
| --- | --- | --- | --- |
| App switcher begin | Command down, Tab down, Tab up | 10 ms | 20 ms |
| One slide step | Tab down, Tab up | 10 ms | 20 ms |
| Commit | Command up | 0 ms | 10 ms |
| Escape or Return | key down, key up | 10 ms | 20 ms |

These are derived from the two constants, not measured. The `keyPost` tracker
measures the real thing continuously; see **Continuous measurement** below.

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
- Sum on busy, not drop. `flushTravel` in `iPhone/Input/InputUplink.swift`
  keeps the accumulated travel when the radio refuses a single-frame message and
  retries on the transport's `onReadyToSend` callback. A message that needs more
  than one fragment still queues whole, and a click forces a queued flush so it
  cannot overtake the travel before it.
- One pacer. `TrackpadGestureEngine` no longer rate limits;
  `displayCadenceLimitHz` is gone and `CursorMixer` (16 ms) is the
  only pacer on the path.
- The air mouse rides the same frame and the same retry.
  `SharedMotionProtocolAdapter` is deleted. The `motionPointerDelta` protocol
  case stays for the Mac's decoder.
- The air mouse shares the pacer too. Core Motion samples hand off to the main
  queue as they arrive (`DeltaCoalescer.motionPointer()` no longer paces) and
  join `CursorMixer.handleTravel`, so cursor travel updates at
  about 60 Hz from either sensor instead of 25 Hz from the air mouse, and two
  sensors moving one cursor cannot each spend a full packet budget.
- `CursorTravel` (`iPhone/Input/CursorTravel.swift`) keeps the sub-point
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

## Where the stages live

The input path was pulled out of the view model on 2026-09-03. Sensors, mixer,
uplink, session, and transport are now separate stages. There are two protocols:
`InputLink` hides sealing and sequencing from the pipeline, and `MessageLink`
hides the wire from everything above it, sealing included. A new transport is
one more `MessageLink`. See `docs/input_pipeline.md`.

## How to measure

**Bluetooth round trip.** Settings tab, tap Ping Mac. It sends five pings 250 ms
apart and reports average, best, and how many came back, under Link round trip.
Pongs carry no identifier and are matched to sends in order; the spacing is far
wider than the round trip, which keeps that honest. One-way is roughly half.
Samples also land in the phone debug log as `ping_rtt`.

**Mac key posting.** Use a hotkey, then read `keyPostMs` from
`./scripts/debug-mac.sh`. It is the wall time for the last paced burst, from
hand-off to its final event reaching the window server.

**What is not measured.** The Dock's own reaction. It is the only step left
that neither app can see. The touch-to-send step is now covered by
`input.gesture->wire` below.

## Continuous measurement

The two probes above answer a question only when you go and ask. Every stage on
the cursor and voice paths now also keeps a running window, so a slowdown can be
found after the fact instead of reproduced.

`LatencyTracker` (`Shared/Observability/LatencyTracker.swift`) is a 256-sample
ring buffer, about four seconds of cursor traffic at 60 a second: long enough to
show a stall, short enough to forget one. Recording takes a lock, writes one
slot, and bumps an index. No allocation, no formatting, no sorting. Sorting
happens only when a summary is read.

Three things about reading it:

- **Samples are microseconds.** Most stages are under a millisecond, and a stage
  that always reads zero teaches nothing.
- **`refused=` is the number to watch.** A link falling behind shows flat
  timings and a climbing refusal rate, because a message that never went out has
  no duration to record. Timings alone will not show it.
- **`refused=` and its attempt count are running totals**, while the timings are
  a rolling window. The recent refusal rate is the difference between two
  readings, not the number on any one of them.

`LatencyClock` is the stopwatch. It is monotonic on purpose: the wall clock can
step sideways when it is corrected, and a negative duration in the middle of a
latency window is worse than no measurement at all.

Neither type can ever see a payload, so nothing typed or said can reach a
timing. That is a boundary, not an accident; see `docs/worker_learnings.md`.

**Mac.** `./scripts/debug-mac.sh` returns a `latency` array in `/state`, seven
entries defined in `Mac/Debug/MacLatencyProbes.swift`:

| Name | Times |
| --- | --- |
| `receiveToInject` | A whole received message, from the link handing it over to the effect being applied |
| `decrypt` | Opening the sealed message |
| `decode` | Turning plaintext into an envelope |
| `dispatch` | Routing the decoded message to the thing that acts on it |
| `keyPost` | One paced key burst, hand-off to the last event reaching the window server |
| `linkSend` | One message on its way back to the phone |

`decrypt`, `decode`, and `dispatch` are the inside of `receiveToInject`, so they
sum to roughly it. If the total is high and the three parts are not, the time
went somewhere none of them covers.

**Phone.** `./scripts/debug-phone.sh` shows a `latency` event, emitted every five
seconds while the app is in front and connected. A phone in a pocket measures
nothing. Five trackers, defined in `iPhone/Debug/PhoneLatency.swift`:

| Log key | Name | Times |
| --- | --- | --- |
| `linkData` | `link.send.data` | Cursor, click and typed traffic into Core Bluetooth |
| `linkCtrl` | `link.send.control` | Handshake traffic, kept apart so a slow pairing does not read as a slow cursor |
| `input` | `input.gesture->wire` | Seal plus wire for one input message |
| `held` | `input.held` | How long accumulated travel sat waiting on a busy link. This is the lag the hand feels |
| `rtt` | `link.rtt` | Phone to Mac and back, sampled automatically every couple of seconds |

Subtract `link.send.data` from `input.gesture->wire` and what is left is the
phone's own sealing cost.

`link.rtt` counts a refusal when a pong never comes back. Without that, one lost
pong would pair every later pong with an older send and the round trip would
read long for as long as the link stayed up.

### Reading the three cases

- **`input.held` high with `link.send.data` refusals climbing.** The wire is the
  bottleneck and messages are backing up behind it.
- **`receiveToInject` high.** The Mac is slow, and its three parts say which
  piece.
- **Everything low and it still feels laggy.** The lag is `link.rtt`, which is
  the radio's own heartbeat. No code above the transport can fix that.

## Measured

2026-09-03, phone on the desk beside the Mac, both apps foreground.

| What | Value |
| --- | --- |
| Bluetooth round trip | 53, 58, 68, 77, 85 ms. Average 68, best 53. |
| One way, inferred | roughly 30 ms |
| Mac key posting, commit queued behind a begin | 49 ms measured |
| Mac key posting, idle queue | superseded; see the 2026-09-04 reading below |

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

### 2026-09-04, first reading from the rolling probes

Phone beside the Mac, both apps foreground, roughly forty seconds of trackpad
and one push-to-talk utterance. Only the iPhone was connected over Bluetooth, so
nothing else was competing for the radio.

| Stage | Median | p95 | Worst | Refused |
| --- | ---: | ---: | ---: | ---: |
| `link.rtt` | 68 ms | 101 ms | 123 ms | 0 of 22 |
| `input.gesture->wire` | 0.57 ms | 0.64 ms | 0.98 ms | 0 of 22 |
| `link.send.data` | 0.13 ms | 0.21 ms | 0.23 ms | 0 of 89 |
| `receiveToInject` | 0.23 ms | 1.82 ms | 9.50 ms | 0 of 86 |
| `decrypt` | 0.07 ms | 0.19 ms | 7.74 ms | 0 of 153 |
| `decode` | 0.02 ms | 0.25 ms | 1.75 ms | 0 of 153 |
| `dispatch` | 0.09 ms | 1.26 ms | 1.52 ms | 0 of 86 |
| `keyPost` | 1.76 ms | | | 0 of 1 |
| `voiceCommitToTyped` | 1234 ms | | | 0 of 1 |

What it says:

- **The radio is the whole cost.** 68 ms round trip is about 34 ms each way,
  which is the 30 ms connection interval plus change. Every software stage on
  both sides is under 2 ms, so code contributes roughly one part in thirty.
- **Nothing is backing up.** Zero refusals across 89 sends, and `input.held`
  produced no samples at all, meaning travel never once waited for room. The
  keep-and-retry path is present but was not needed at this traffic level.
- **`voiceCommitToTyped` was the speech model, not the link.** 1.2 s from
  commit to text in the field, against a 0.13 ms wire cost for the audio chunks
  that fed it. That tracker and the audio chunks are gone: the phone transcribes
  now and only the finished text crosses. The row is left here because it is
  what the run measured.

The old advice stands and is now measured rather than argued: the connection
interval is the floor, and no code above the transport can move it.

### A run of one repeated key, 2026-09-04

The worry was that identical key events posted with no gap would be coalesced
by the window server, or read as a key repeat, and that characters would
silently go missing. That would be serious for the delete slide, whose whole
design rests on knowing exactly how many characters left.

It does not happen. `/keyburst?count=N` types its own filler into the focused
field, presses Delete `N` times as one unpaced run, and reports how many
characters actually left:

| Target | Asked | Removed |
| --- | --- | --- |
| TextEdit, `AXTextArea` | 8, 20, 40, 64 | 8, 20, 40, 64 |
| Chromium textarea | 20, 64 | 20, 64 |
| Chromium, 64 five times over | 64 each | 64 each |

Key repeat is a flag the sender sets on the event, not something worked out
from timing, and the window server coalesces mouse-moved events rather than
key events. Typed text has always gone out unpaced through the same queue,
with an identical key code on every event, and has never dropped a character.

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
