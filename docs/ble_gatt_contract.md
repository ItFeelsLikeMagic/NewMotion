# BLE GATT and byte-framing contract (MVP v1)

This document is the single source of truth for the custom BLE service used by
the foreground iPhone peripheral and the macOS central. The service is
application transport only; it is not a Bluetooth HID service and it does not
replace the application authentication handshake.

Everything here describes **one** implementation of `MessageLink`
(`Shared/Transport/MessageLink.swift`), the seam the rest of the app talks to.
Nothing above that protocol knows any of the detail below, so a second transport
can be added without touching this document. The code for this one lives in
`Shared/Transport/BLE/`, `iPhone/Link/BLEMessageLink.swift`, and
`Mac/Link/BLEMessageLink.swift`. See `docs/input_pipeline.md` for the seam
itself.

## Service and characteristics

The iPhone advertises exactly one custom primary service:

| Name | UUID | iPhone role | Properties |
| --- | --- | --- | --- |
| Phone Remote service | `A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1000` | Advertised primary service | — |
| Phone-to-Mac data | `A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1010` | Notify/read | `.notify`, `.read` |
| Mac-to-Phone data | `A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1011` | Receives writes | `.write`, `.writeWithoutResponse` |
| Phone-to-Mac control | `A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1020` | Notify/read | `.notify`, `.read` |
| Mac-to-Phone control | `A6E3C5D4-1F4A-4F9D-8F35-4D5B8D3C1021` | Receives writes | `.write`, `.writeWithoutResponse` |

The service is advertised only while the iPhone app is foregrounded, the
peripheral manager is `.poweredOn`, and the app has an allowed pairing/session
state. The Mac scans only for the service UUID above. The characteristic UUIDs
are validated after discovery; a connection is not ready until all four are
present and the two phone-to-Mac characteristics are subscribed.

The control channel carries framing and transport acknowledgements. The data
channel carries application envelopes. A control frame is never interpreted as
an application message, and a data frame is never used as an acknowledgement.

## Frame encoding

Every GATT value is one complete frame. Multi-frame logical envelopes use the
same `messageID` and are reassembled by the receiver. All integer fields are
unsigned big-endian. The fixed header is 16 bytes:

| Offset | Size | Field | Values/meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `version` | `1` |
| 1 | 1 | `kind` | `1` data, `2` control |
| 2 | 1 | `flags` | bit 0 reliable, bit 1 first, bit 2 last; other bits zero |
| 3 | 1 | `reserved` | zero; non-zero is invalid |
| 4 | 4 | `messageID` | non-zero sender-local logical message identifier |
| 8 | 2 | `fragmentIndex` | zero-based index |
| 10 | 2 | `fragmentCount` | total fragments, 1…2048 |
| 12 | 2 | `payloadLength` | bytes following this header |
| 14 | 2 | `reserved` | zero; non-zero is invalid |

`payloadLength` must equal the received value length minus 16. A one-fragment
frame must set both first and last; a multi-fragment sequence must set first
only on index 0 and last only on index `fragmentCount - 1`. Fragment indices
must arrive in order for a given message. A receiver may discard an incomplete
message when a new message begins, but it must never deliver a partial payload.

The logical payload is a serialized shared protocol envelope. The BLE layer
does not inspect or reinterpret that envelope. `Shared/Protocol` must therefore
keep its maximum encoded envelope at or below 8,192 bytes, which is the BLE
reassembly limit in this MVP.

## Negotiated sizes and bounds

The sender uses the Core Bluetooth negotiated write/notification value length
for the active link. The 16-byte header is included in that value. The
smallest interoperable value length is 20 bytes (the default ATT payload), so
the smallest fragment payload is 4 bytes. A link may negotiate a larger value;
the sender must recompute the fragment payload size and must not assume a
particular MTU.

The following hard limits prevent an untrusted peer from causing unbounded
allocation:

- maximum logical envelope: 8,192 bytes;
- maximum fragments: 2,048;
- maximum queued outbound frames per characteristic: 128;
- maximum partial reassembly bytes: 8,192;
- maximum reliable in-flight messages: 32;
- reliable retry limit: 3 attempts, with a 500 ms acknowledgement timeout.

An envelope larger than 8,192 bytes is rejected before fragmentation. With the
20-byte minimum value length, an 8,192-byte envelope requires at most 2,048
fragments (and therefore fits the fragment-count field and bound). A
zero-length logical envelope is valid only if the shared protocol explicitly
defines one; a frame itself may never have a zero-byte payload because it
would waste a transport transaction.

## Delivery and disconnect rules

- Data and control values are ordered per characteristic. Cross-channel order
  is not guaranteed; the protocol sequence number is authoritative.
- Unreliable frames may be dropped under backpressure. Reliable frames are
  queued with a bounded retry budget and are acknowledged on the control
  channel by message ID.
- `.writeWithoutResponse` is used only while the adapter reports available
  capacity. `.write` is used for bounded reliable/control writes where the
  platform permits it.
- A queue-full result causes backpressure to the feature producer; it must not
  grow an unbounded memory queue.
- Invalid version, kind, flags, reserved bits, length, fragment count, or
  fragment order causes the offending logical message to be discarded and a
  protocol error to be surfaced without crashing the app.
- A disconnect clears partial reassembly, outbound queues, retry timers, and
  pending acknowledgements. No fragment from the previous connection can be
  combined with a later connection.

## Connection state machine

The public state names are:

`idle → waitingForBluetooth → publishing → advertising → connected → ready`

Any state can enter `stopped` on app backgrounding, Bluetooth unauthorized,
unsupported, powered-off, resetting, or an explicit stop. A central may pass
through `scanning → connecting → discovering → subscribing → ready`; malformed
services, cancellation, timeout, or disconnect return it to `idle`.

`ready` means the required characteristics have been validated and
subscriptions are active. It does not mean that the application pairing or
encrypted session is authenticated. Input and other feature messages remain
blocked until the pairing state machine authorizes them.

## Verification note

The implementation tests frame sizes at 20, 23, and larger negotiated value
lengths. The 20-byte case provides the 4-byte minimum fragment payload used to
prove the 8,192-byte/2,048-fragment bound. Physical radio latency and recovery
results belong in `docs/verification/gate-b-ble.md`; this contract makes no
performance claim.
