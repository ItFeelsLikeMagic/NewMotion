# Input pipeline

How a finger or a wrist turn becomes a cursor move on the Mac, and where each
concern lives. One rule runs through it: a stage knows the stage below it by a
protocol, never by what is actually down there.

## The stages

| Stage | Lives in | Owns | Does not know |
| --- | --- | --- | --- |
| Sensors | `TrackpadGestureEngine`, `MotionPointerFilter` | Touch and attitude to points, each in its own units | That another sensor exists |
| Mix | `iPhone/Input/CursorMixer.swift` | Summing travel from every sensor, one 16 ms pace, discrete events held behind travel | Which sensor, and what a packet is |
| Uplink | `iPhone/Input/InputUplink.swift` | Whole-point travel, the remainder, packing, retry, send order | Bluetooth, crypto, fragments |
| Link | `iPhone/Input/InputLink.swift` (protocol) | The contract: take this message, tell me when there is room | Nothing above it |
| Bluetooth | `iPhone/Input/BLEInputLink.swift` | Session, envelope sequence, message IDs, fragmenting, channels | What input means |

`CursorTravel` is the small ledger the uplink keeps: whole points go out, the
fraction stays for the next packet.

## Why the seams are where they are

- **Sensors keep their own tuning.** The trackpad thinks in points per finger
  millimetre, the air mouse in points per radian of wrist turn. Merging that
  into one "sensitivity" would mean one of them lying about its units. What they
  share is the output: points of travel.
- **The mixer is source-agnostic.** Two sensors moving one cursor must not each
  spend a full packet budget, and the link, not the digitizer or the gyro, sets
  the useful rate.
- **The uplink is transport-agnostic.** Keep-do-not-drop, the sub-point
  remainder, and "a click never overtakes the travel before it" are true on any
  wire, so they sit above the wire.
- **The link is the only thing that changes for a new transport.** Wi-Fi or USB
  means writing one more `InputLink`. Nothing above it moves.

## Swapping the transport

Write a type conforming to `InputLink`:

- `isReady` says whether input can go at all.
- `send(_:delivery:)` takes one message. `.latestWins` may be refused with
  `.busy`, and the uplink keeps the value and resends. `.ordered` must queue.
- `onReadyToSend` fires when a link that answered `.busy` has room again.

Then build `InputUplink(link:)` with it. Sealing, size limits, and fragmenting
are the new link's business, exactly as they are BLE's today.

## Ordering

Two stages enforce the same rule at different distances from the wire, and both
are needed:

- The mixer flushes pending travel before it passes a click along, so the pacer
  cannot hold travel behind it.
- The uplink flushes its ledger as `.ordered` before a click, so the radio
  cannot deliver the click first.

## What is deliberately not here

- Voice has its own path (`VoiceUplink`), because it is a stream with its own
  queue and its own message ID range, not discrete input.
- The handshake stays on the model and the control channel. It is not input.
