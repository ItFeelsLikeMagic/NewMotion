# Trackpad latency backlog

Cursor lag showed up as backpressure: a move would land late and then catch up
after the finger stopped. The measured cause was packet cost. One cursor move
cost about 282 bytes on the radio (206-byte JSON envelope, 60 bytes of AEAD,
16-byte BLE header) to carry four bytes of movement, and the phone discarded a
move outright whenever Core Bluetooth had no room for it.

## Landed 2026-09-03

- `PointerStreamFrame` (`Shared/Protocol/PointerStreamFrame.swift`): 11 bytes of
  plaintext for one delta instead of 206, encrypted as message type
  `pointerDelta` and recognised by its `PRP1` magic. Several deltas ride in one
  frame. About 87 bytes on the wire against 282.
- Sum on busy, not drop: `flushCursorStream` in `iPhone/PhoneRemoteApp.swift`
  keeps the accumulated travel when the radio refuses a single-frame message and
  retries on the transport's new `onReadyToSend` callback. A message that needs
  more than one fragment still queues whole, and a click forces a queued flush so
  it cannot overtake the travel that preceded it.
- One pacer: `TrackpadGestureEngine` no longer rate limits. `displayCadenceLimitHz`
  is gone; `TrackpadOutputCoalescer` (16 ms) is the only pacer on the path.
- The Mac no longer hops each received frame through `Task { @MainActor }`.
  Core Bluetooth already calls back on the main queue, so the hop only queued
  packets behind whatever the main actor was doing. Same fix as the phone's
  motion sink.

## Future experiments, not started

Lossless:

1. Move the air mouse onto `PointerStreamFrame` as well. `motionPointerDelta`
   still pays the full JSON envelope on every Core Motion flush.
2. Keep the debug snapshot off the 60 Hz path. Every received packet sets
   `lastApplicationMessage`, whose `didSet` rebuilds the whole
   `MacDebugSnapshot` and republishes it to SwiftUI. Throttle it, or skip it for
   pointer and scroll.
3. Cache the cursor position on the Mac. `CGEventInputSink` asks the window
   server for the current location on every move
   (`CGEvent(source: nil)?.location`). Track the last posted point and re-sync
   only after an idle gap.
4. Shrink the AEAD header for the fast path. 60 bytes now dominates an 87-byte
   cursor packet: a 4-byte session tag and a 2-byte counter would take a single
   delta to about 40 bytes. Security review required.

Lossy:

5. Cap how far ahead the phone may run. Hand Core Bluetooth at most one cursor
   packet and hold the sum for everything else, so the radio can never build a
   backlog to replay.
6. Merge the Mac's backlog into one cursor move per screen frame. The cursor
   lands where the finger is now instead of tracing the old path.
7. Pointer acceleration curve on the phone. Gain is linear today, so a fast
   flick needs as many packets as a slow drag. A curve covers more screen per
   packet and keeps slow moves precise.
8. Deadline drop. Discard a cursor delta older than about 60 ms once a newer one
   exists. Only meaningful together with 5 or 6.

## Open bug found while measuring

`IPhoneBLEPeripheralTransport.send` calls `updateValue` directly even when the
same channel already has queued frames, so a new cursor frame can jump ahead of
a queued voice fragment and break reassembly on the Mac. Not triggered by the
cursor path itself (single-frame cursor messages never queue), but it is real.
