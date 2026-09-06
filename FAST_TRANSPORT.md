# A faster wire than Bluetooth

Shelved design note. A Wi-Fi transport was built end to end on a branch,
measured on real hardware, and then put down. Nothing in this document is in
`main`. It exists so the feature can be rebuilt without rediscovering the same
traps, and it is written to be read on its own.

Two separable pieces of work came out of it:

1. **A second wire.** Wi-Fi alongside Bluetooth, chosen automatically, with a
   silent upgrade and downgrade. Large, and only half proven.
2. **How the cursor is steadied.** A rewrite of `SmoothedTravelSink` that is
   not about Wi-Fi at all and is probably worth shipping on its own.

Read part 6 first if you only want the second one.

---

## 1. Why

`docs/latency.md`'s Bluetooth reading is the whole motivation: a round trip of
**68 ms median, 101 ms p95**, while every software stage on both sides is under
2 ms and sends are almost never refused. The radio is the entire cost, and the
BLE connection interval is not ours to move.

So the goal was never "add AWDL". It was: **scan the QR code once, and from
then on the remote runs on the fastest wire the two machines can reach each
other on, moving between wires on its own.**

## 2. What was measured

On an iPhone 15 Pro Max and an M1 Max MacBook Pro, using the existing
`link.rtt` probe.

| Wire | p50 | p95 | Worst |
| --- | --- | --- | --- |
| Bluetooth (the recorded baseline) | 68 ms | 101 ms | |
| Wi-Fi, early runs, wire not yet separable | 11-13 ms | 90-102 ms | |
| Wi-Fi peer to peer, measured directly | ~10 ms | ~294 ms | 338 ms |
| Wi-Fi shared network, on its own | never cleanly measured | | |

Read that table carefully, because it is the single most important result:

- **Typical latency collapses.** 68 ms to about 10 ms. The feature works.
- **Peer to peer's tail is far worse than Bluetooth's.** A 294 ms p95 against
  Bluetooth's 101 ms. Peer-to-peer Wi-Fi is duty-cycled: the radio hops between
  the infrastructure channel and the peer channel, and nothing we tried moved
  that. `serviceClass` was swept across `.responsiveData`, `.interactiveVideo`
  and `.interactiveVoice` and the three were indistinguishable.
- **The case that matters was never isolated.** Both machines on the same
  network is the overwhelmingly common case and it is the one with no clean
  number. Get that number first next time.

Also ruled out, so nobody repeats them:

- Backpressure is not a factor. 0 refusals in 2,361 attempts;
  `input.gesture->wire` p50 0.11 ms.
- `includePeerToPeer` being on does not itself cost anything. Turning it off
  changed nothing: p50 10.96 ms, p95 90.27 ms.

Unexplained and still open: a round-trip hiccup of roughly 90 ms every 20 to
40 seconds, on every configuration tested. The leading guess is Wi-Fi power
save (see 6.5), but it was never proven.

## 3. The design

### The seam already exists

`Shared/Transport/MessageLink.swift` hides the wire from everything above it.
Sealing, pairing, trust, the input pipeline and the voice path are all
transport-neutral already, and the QR token already carries the pairing ID and
the Mac's display name. Adding a wire means writing one conformer and changing
no caller.

### The key insight: a wire change is not a reconnect

The pairing session lives **above** the link, not bound to a socket. The phone
only tears a session down when the link reports `.searching`.

So if a composite link keeps reporting `.connected` while *any* child wire is
up, swapping wires underneath is invisible. The next sealed envelope goes out
the other socket, the Mac decrypts it with the same session, and nothing above
notices. No re-handshake, no dropped session, no blip. Only losing every wire
reports `.searching`, which runs the existing reconnect path unchanged.

Everything else follows from that one property. Two consequences must be
honoured or it breaks:

- **`maximumMessageBytes` is the minimum across children**, never the active
  child's. Otherwise a message sized against Wi-Fi's 8,192 comes back
  `.tooLarge` the moment it downgrades to Bluetooth.
- **Sequence numbers arrive slightly out of order across a swap**, because a
  packet in flight on a 34 ms hop can land after one sent on a 2 ms hop. The
  replay window in `Shared/Crypto/PairingHandshake.swift` tolerates this. Its
  real tolerance was measured at **63, not 64**: the window has 64 slots but
  slot zero belongs to the highest sequence seen. Write that test first; if it
  fails, this whole design is wrong.

### Three wires, not two

The first build had one Wi-Fi wire that asked the connection which interface it
was using. That was wrong, and the way it was wrong is worth keeping:

`NWConnection.currentPath.availableInterfaces` lists the interfaces a path
**could** use, not the one carrying bytes. The Mac confidently reported
`awdl0` while `netstat -ib` showed awdl0's counters frozen and en0 moving
458 KB. Both apps agreed with each other and both were wrong.

The fix is structural. Make the mode known by construction:

| Wire | Parameters |
| --- | --- |
| Wi-Fi (shared network) | `includePeerToPeer = false` |
| Wi-Fi (peer to peer) | `includePeerToPeer = true`, plus `prohibitedInterfaces = <every interface the default path currently offers>` |
| Bluetooth | unchanged |

Peer to peer is reached by ruling everything else out. There is no public AWDL
API, and an AWDL interface reports as `.wifi`, the same type as the one
carrying the home network, so it cannot be asked for. Prohibiting what the
default path offers is what leaves it. Read `prohibitedInterfaces` from a live
`NWPathMonitor` at the moment parameters are built, not once at startup.

After this change every interface-sniffing line was deleted. Do not add them
back.

### Composites

**Phone: pick the wire.** A `MessageLink` over an ordered list of
`(kind, link)` children, best first. Preference is list order; nothing compares
kinds. It owns the callback slots, installs its own on each child and re-emits
upward, so everything above is built once and never learns the wire changed.

- Active child is the highest-preference child that is `.connected`, and it is
  sticky: losing it falls back **instantly**, on the same turn; a better wire
  must hold `.connected` for **2 seconds** before it takes over. Without the
  delay a flapping link thrashes; without the instant downgrade the remote goes
  dead while a good link sits idle.
- Reported state is the aggregate, the highest child state by rank. **A swap
  between two connected children therefore emits nothing**, which is what keeps
  the session alive.
- Policy is `automatic` or `pinned(kind)`. Pinning stops the other children: a
  disconnect then leaves the link searching on the pinned wire rather than
  falling back, because that is what picking means.
- In automatic mode every wire stays warm. Stopping the loser would make
  falling back cost a rediscovery, which is exactly what we are trying to
  avoid.

**Mac: answer where you were called.** Same shape, no policy. The Mac cannot
know the phone's preference before a link exists, so it listens on everything
and routes every send to whichever child last delivered a message. Every
message the Mac sends is a reply, so that is always well defined. Before any
message has arrived, `send` returns `.notConnected`, which is correct.

**The Mac listens, the phone browses.** iOS has no background mode that keeps
an `NWListener` alive.

## 4. The wire contract

Enough to reimplement without reading the Swift.

### Discovery

The Mac publishes one Bonjour service per Wi-Fi listener; the phone browses.

| | Value |
| --- | --- |
| Service type | `_newmotion._tcp` (the branch used `_phoneremote._tcp`) |
| Domain | default |
| Instance name | the Mac's display name |
| Transport | TCP, listener-assigned port |

iOS refuses to browse a service type the app has not declared, so the type must
also appear in `NSBonjourServices` in the iPhone Info.plist. Both platforms
need `NSLocalNetworkUsageDescription`; macOS 15 and later enforces it too. No
entitlement is needed while the Mac app is unsandboxed with hardened runtime
off.

TXT record:

| Key | Meaning |
| --- | --- |
| `v` | Wire version, `1`. Covers framing and this layout together |
| `dn` | The Mac's display name. Presentation only |
| `pid` | Comma-separated pairing tags: one per trusted phone, plus the pairing ID of any QR offer currently on screen |

**`pid` is the only selection criterion.** A phone dials an advert if and only
if `v` matches and `pid` contains the tag of the pairing ID it is trying to
reach: the scanned token's `pairingID` while pairing, the trusted Mac's
`deviceID` on a reconnect. `dn` is never consulted, because a stranger can name
their Mac anything.

```
pairingTag(id) = first 8 chars of hex(SHA256(utf8(lowercase(id.uuidString))))
```

Lowercase the UUID string first or the two sides will not agree. Hash rather
than publish the raw ID: mDNS is broadcast to everyone on the network, and the
pairing ID is also used by the handshake. Every entry must be exactly 8
lowercase hex characters; one malformed entry rejects the whole record, so
loose formatting fails closed. A record that fails to decode is simply not a
candidate, not an error.

With no matching advert, keep browsing. **Do not dial the first Mac that
answers and let the handshake sort it out**: a failed handshake runs the
pairing failure path, which backs the phone off for up to eight seconds.
Re-evaluate candidates when the pairing ID changes as well as when the browse
results change, so a token scanned after browsing began does not wait for the
next mDNS update.

The Mac rewrites the TXT record in place when the tag list changes, so a QR
offer appearing or expiring costs no listener restart and drops no connection.

### Framing

TCP delivers every byte once, in order, so there is no fragmentation and no
reassembly. One header, one payload, repeated. Unsigned big-endian.

| Offset | Size | Field | Values |
| ---: | ---: | --- | --- |
| 0 | 1 | version | `1` |
| 1 | 1 | kind | `1` data, `2` control |
| 2 | 2 | reserved | zero; non-zero is invalid |
| 4 | 4 | payload length | 1…8,192 |
| 8 | n | payload | one serialized protocol envelope |

- `kind` repeats the BLE frame numbering so a capture off either wire reads the
  same way. One connection carries both channels; BLE needed two
  characteristics so a handshake would not queue behind cursor traffic, and
  here the handshake completes before any cursor traffic exists.
- Delivery reliability puts nothing on the wire. Every TCP send is reliable and
  ordered, so a reliability bit would be dead metadata; it stays purely a
  backpressure policy.
- **A bad version, length or reserved field is fatal for the connection**, not
  just the message. A stream cannot resync.

### Connection parameters

```
tcp.noDelay = true
tcp.enableKeepalive = true, keepaliveIdle = 2, keepaliveInterval = 1, keepaliveCount = 2
tcp.connectionTimeout = 3
parameters.includePeerToPeer = (wire == .peer)
parameters.prohibitedInterfaces = <default path's interfaces>   // peer wire only
parameters.serviceClass = .interactiveVoice                      // honest label, not a measured win
```

Keepalives are what make downgrade prompt. Bluetooth reports a disconnect when
the phone walks away; TCP over Wi-Fi sits on a dead path for minutes without
probes. Two probes a second after two idle seconds puts worst-case detection
near four.

**TCP, not QUIC.** Over a local link carrying 87-byte cursor packets, stream
multiplexing and 0-RTT buy nothing measurable and cost real complexity. If
head-of-line blocking ever shows up in a measurement, the fix is a second
connection for the control channel, not a protocol change.

### Backpressure

`NWConnection.send(completion: .contentProcessed)` fires when the transport
accepts the bytes, not when the peer acks. So the watermark is a stall
detector, not a rate limiter, and a refusal should be rare and meaningful.

Track outstanding bytes, header plus payload of every frame whose completion
has not fired. Two marks:

- **Soft, 16 KB.** Latest-wins and unreliable traffic refuse above it. Cursor
  deltas are ~87 bytes, so that is ~180 packets of slack; reaching it means the
  path has genuinely stopped, which is exactly when the cursor mixer should
  keep accumulating travel rather than queue a path the hand has left.
- **Hard, 256 KB.** Reliable traffic refuses only above this. Both apps treat a
  non-sent handshake message as a handshake failure, so a 200-byte handshake
  must not be refused because a voice burst filled the soft mark.

`send` returning false must mean **only** that the connection is gone. A full
buffer must never come back that way, or the app drops the message instead of
waiting.

## 5. The UX

In the phone's settings, beside the existing Link and round-trip rows:

```
Link                 Connected
Transport            Wi-Fi (shared network)     <- read-only, always the live wire
Link round trip      3.1 ms average

[x] Automatic (Recommended)
Transport            [ Wi-Fi (peer to peer)  v ]   <- greyed out while Automatic is on
```

- The status row is read-only and shows the live wire, or "None".
- Automatic defaults on and persists.
- The picker is disabled while Automatic is on, and mirrors the live wire so it
  can never contradict the status row. Turning Automatic off seeds the
  selection from whatever is live, so flipping the toggle never changes the
  connection by itself.
- A stored preference naming a wire this build does not have must fall back to
  automatic. Pinning whichever wire happens to sort first would strand the
  phone on it.

## 6. Cursor feel

**This part is independent of Wi-Fi and is the piece most worth keeping.** It
was found while chasing a stutter, but nothing in it depends on a second wire.

### 6.1 macOS quantises the cursor to whole points

Measured directly, not assumed. Setting the cursor to a fractional offset and
reading it back:

```
asked +0.25 -> got +0.0
asked +0.5  -> got +0.0
asked +0.75 -> got +0.0
```

So sub-point interpolation is impossible. The smallest step a cursor can take
is one point, and **the filter must keep the fraction itself** or slow motion
is thrown away entirely. Do not try to make motion finer by inventing in-between
positions; it cannot work.

### 6.2 The old glide was quietly doing two jobs

`SmoothedTravelSink` spread each arriving packet over the next 4 display frames
(33 ms), a constant sized against Bluetooth's ~30 ms batching. That was doing:

1. **Filling the gap** between packets, so one packet does not land as a single
   jump.
2. **Averaging**, because each frame got a blended slice rather than the raw
   packet, which flattened hand tremor.

Only the first was documented. Sizing the glide to the *measured* packet rate
finished job one correctly and silently ended job two, and the cursor went from
smooth to jittery. That failure is the most useful thing in this document.

### 6.3 Constants sized per packet are a bug class

Both of these were per-packet quantities whose meaning changed the moment the
packet rate changed:

- the 4-frame glide, sized against Bluetooth's arrival rate;
- the "skip moves under N points" threshold, since halving the send interval
  halves the travel in each packet and pushes far more of them under the line.

If a constant is expressed in packets, it is wrong on the next wire. Express it
in time or in speed.

### 6.4 What replaced it: chase, do not spread

One loop covers both jobs on any wire, with no packet-rate measurement and no
transport branch:

- Add arriving travel to *where the hand is*, kept relative to the cursor.
- Once per display frame, move the cursor a fraction of the remaining distance.
  Emit whole points; keep the remainder.

On a slow wire the fraction keeps being applied between packets, which glides
through the gap. On a fast wire the target is always moving, so the output is a
blend of the last several packets. Both jobs fall out of the same line.

The fraction is set from hand speed, which is the **one-euro filter**: a still
hand is steadied hard, because tremor is what you notice when still; a sweeping
hand is barely touched, because lag is what you notice at speed. Two knobs, both
exposed as sliders in the Mac app:

- **Steadiness**, mapped to the cutoff when nearly still, 30 Hz down to 2 Hz.
- **Snap**, how fast the cutoff rises with speed, up to 0.032 Hz per point per
  second.

Both defaulted to the middle of their range. Those defaults were never tuned by
feel on hardware; treat them as a starting point.

Properties worth keeping in the tests: the cursor never overshoots, so it can
never step backwards while the hand goes one way; total distance is exact; a
click flushes the chase so it lands where the cursor was heading; travel under
half a point waits for more rather than being lost.

**Unproven:** this was only ever felt on Wi-Fi. The argument that it reproduces
the old feel on Bluetooth is reasoning, not a measurement.

### 6.5 Two smaller findings

- **Wi-Fi lets the phone send twice as often.** The cursor mixer paced at 16 ms
  because that is what BLE airtime was worth. At 8 ms the Mac gets a real
  sample for every frame of a 120 Hz display instead of one spread across two.
  About 10 KB/s, which Wi-Fi does not notice. Retime the pacer when the active
  wire changes; do not hardcode it.
- **An idle Wi-Fi radio powers down**, and the first packet after a pause waits
  for it to wake. This is the leading explanation for lag at the start of a
  move after a rest, and possibly for the 90 ms hiccup in part 2. A packet sent
  when a finger lands on the glass, before it travels, hides it: the finger
  touches down well before it moves. Gate it on the link having been quiet, so
  a move in progress never pays for it. **This was never confirmed.**

## 7. Traps

Each of these cost real time.

- **A dial with no timeout hangs forever.** This was the worst one. Set
  `tcp.connectionTimeout`. The peer wire prohibits every normal route, so a dial
  to an advert with no route left sits in `.preparing` indefinitely. And
  because the composite ranks `connecting` above `searching`, that one stuck
  child hid a perfectly healthy Bluetooth link and blocked every retry: the
  phone showed "Connecting" and rescanning the QR code changed nothing.
- **`start()` must be a no-op while connected.** The phone calls it on every
  foreground and every reconnect attempt. The BLE link deliberately tears down
  and rescans; a Wi-Fi link that copies that drops a healthy session every time
  the app comes forward. This is the easiest way to ship a link that "works but
  keeps reconnecting".
- **Callbacks must arrive on the main queue.** The Mac's link callbacks use
  `MainActor.assumeIsolated` and a callback from any other queue crashes them.
  Start the listener, browser and connection on the main queue and do not add a
  private queue with a hop per message; that hop is a recorded regression that
  made a burst of cursor motion replay slowly instead of arriving.
- **Redial when told to reach a different Mac.** If seeking a new pairing ID
  only dials when nothing is connected, scanning a second Mac while connected
  to the first leaves the phone talking to the first, and the handshake fails
  into the backoff. Note this also fires once during ordinary pairing, because
  the phone switches from the scanned `pairingID` to the trusted `deviceID`.
  One redial is expected there.
- **Newest connection wins on the Mac.** After an iOS suspend-kill the old TCP
  connection can take seconds to be declared dead, and refusing the new one
  strands the phone for that long. A stranger on the LAN can then kick the
  phone off repeatedly: a nuisance, not a breach, since the handshake gates
  everything and the authentication timeout restarts the link.
- **The test host must not create an `NWListener`.** Extend the existing inert
  runtime flag rather than adding a second concept, or the suite raises a
  local-network prompt and stops being unattended.
- **Two generators must never run concurrently.** They race on
  `xcshareddata/xcschemes`, and every build and test script generates first. If
  work is split across parallel agents, each needs its own worktree.
- **Both Wi-Fi listeners publish the same service name**, so mDNS renames the
  second to "Name (2)". Harmless, but confusing the first time `dns-sd -B`
  shows two Macs where there is one.
- **Trust the OS counters, not the apps.** When the two apps disagreed about
  the wire, `netstat -ib` sampled twice ten seconds apart settled it in one
  step. Do that before believing any in-app status row.
- **`peerName` stays nil on the Mac's Wi-Fi link.** An accepted connection's
  endpoint is an address, on the peer wire a link-local IPv6. Fall back to a
  constant. Do not reverse-resolve: that is a DNS round trip on the connect
  path for a cosmetic string.

## 8. What was never proven

Do not treat the branch as validated. None of this was tested:

- Shared-network Wi-Fi measured on its own, which is the case that matters.
- Why the phone preferred peer to peer over the shared network when both were
  available. It did this consistently and nobody found out why.
- The 90 ms hiccup every 20 to 40 seconds.
- Whether the wake-on-touch packet actually helps.
- Whether the chase filter matches the old feel on Bluetooth.
- Turning the Mac's Wi-Fi off mid-drag and confirming the cursor keeps moving
  over Bluetooth with no reconnect. **This is the headline claim of the whole
  design and it was never demonstrated on hardware.**
- Local-network permission denied, on either platform.
- Two Macs on one network.
- Background to foreground recovery, and the newest-connection-wins path after
  an iOS suspend-kill.

One known gap, worth writing down rather than building for: Bluetooth has no
equivalent of the `pid` peer check, so in a two-Mac household the phone could
in principle hold Wi-Fi to one Mac and Bluetooth to another. The handshake
would fail on the wrong one and the existing backoff handles it.

## 9. Rebuilding it

Smallest provable step first. Stages 0 and 1 need no radio at all and are where
the design is actually proven.

- **Stage 0, no networking.** Framing, the service descriptor and pairing tag,
  and the transport-kind enum, with tests. Plus the one test the whole design
  rests on: seal ten envelopes, deliver five in order and five with two
  transposed, and assert the session accepts all ten. **If that fails, stop.**
- **Stage 1, the link, still no networking.** The `MessageLink` conformer over
  a fake transport. The state ladder and both backpressure watermarks are
  provable outright here.
- **Stage 2, one real connection.** The single file that imports `Network`,
  both Info.plists, and each app building a Wi-Fi link *instead of* Bluetooth
  behind a launch argument. No composites yet. Prove: scan, pair over Wi-Fi,
  cursor moves.
- **Stage 3, measure.** Before any composite exists, so the numbers describe
  the wire and not the switching logic. Get the shared-network number first.
  **If shared-network p50 is not decisively under Bluetooth's 68 ms, something
  is wrong with the implementation, not the radio.** If peer-to-peer p95 stays
  worse than Bluetooth's 101 ms, as it did, prefer peer to peer only when there
  is no Bluetooth link at all: that is a one-constant change inside the phone
  composite, which is why the preference lives in one place.
- **Stage 4, both wires and the UI.** The two composites, the settings rows,
  and the reconnect path for denied local-network permission, which is
  currently a dead end that shows only as a link stuck on "Off".
- **Stage 5, the hardware run in part 8.** Especially turning Wi-Fi off
  mid-drag.

Part 6 does not belong to any of these stages. It can be built and shipped
against Bluetooth alone, today.
