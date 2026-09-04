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
| Session | `iPhone/Input/SessionInputLink.swift` | The authenticated session and the envelope sequence | Packet size, fragments, any transport |
| Transport | `Shared/Transport/MessageLink.swift` (protocol), `iPhone/Link/BLEMessageLink.swift` | Packet size, message IDs, fragmenting, reassembly, channels, the beacon | What a message means, and what is in it |

`CursorTravel` (`iPhone/Input/CursorTravel.swift`) is the small ledger the
uplink keeps: whole points go out, the fraction stays for the next packet.

There are two protocols, not one, because two different things are being hidden.
`InputLink` hides *how a message is sealed and sequenced* from the pipeline.
`MessageLink` hides *how bytes cross a wire* from everything, including the
sealing. `SessionInputLink` is the one object that sits between them.

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
- **Sealing sits above the transport.** The transport is handed ciphertext and
  never sees a key, so a new wire cannot weaken the encryption by getting it
  wrong. This is why `SessionInputLink` exists as its own object rather than
  being folded into either neighbour.
- **The transport is the only thing that changes for a new wire.** Wi-Fi, USB,
  or a WebSocket means writing one more `MessageLink`. Nothing above it moves.

## Swapping the transport

Write a type conforming to `MessageLink` (`Shared/Transport/MessageLink.swift`):

- `state` reports the four-step ladder `.unavailable`, `.searching`,
  `.connecting`, `.connected`. It stops at `connected`: whether the peer is
  *trusted* is the app's question, not the wire's.
- `send(_:on:delivery:)` takes one whole message and answers `.sent`, `.busy`,
  `.notConnected`, or `.tooLarge`. Cutting the message up to fit is the
  transport's business, not the caller's.
- `onReadyToSend` fires when a link that answered `.busy` has room again.
- `onMessage` delivers one whole reassembled message and the channel it came in
  on. `onStateChange` and `onError` report the rest.
- `maximumMessageBytes` is the largest message the wire will carry whole.
- `start()` and `stop()` bracket the link's own timers and beacons.

Then wrap it: `SessionInputLink(link:)`, and `InputUplink(link:)` on top of
that. Sealing and the envelope sequence are already handled and do not move.

### Two channels

`LinkChannel` splits traffic into `.control` (0) and `.data` (1). This is a
protocol split, not a Bluetooth one: the handshake must keep flowing while
cursor traffic is being refused for want of room, so the two cannot share a
queue. Every transport has to offer both.

### Three delivery words, deliberately not merged

| Type | Layer | Asks |
| --- | --- | --- |
| `DeliveryClass` | Protocol | Does the *receiver* need this guaranteed? |
| `InputDelivery` | Input pipeline | `.latestWins` travel, or an `.ordered` click? |
| `LinkDelivery` | Transport | If there is no room now, is waiting better than giving up? |

They do not line up, which is why they stay separate. Voice is unreliable on the
wire and still worth queueing, because a dropped chunk is a hole in what someone
said, so it is `.unreliableQueued`. Cursor travel is the opposite: it is
`.latestWins`, and the transport must never queue it, because a stored delta
replays a path the hand has already left.

## Backpressure

A `.latestWins` message that finds no room is refused with `.busy` and is *not*
kept by the transport. The uplink keeps the accumulated travel in `CursorTravel`
and flushes again on `onReadyToSend`, so the cursor ends up where the hand is
instead of undershooting and then catching up. `PhoneLatency.inputHeld` times
how long that wait lasted.

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
