# Shared protocol v1

The shared module defines a transport-neutral JSON envelope. BLE framing and
CryptoKit encryption are separate tickets. The future authenticated session
must authenticate the envelope header and the typed payload as one boundary;
this module does not claim that plain JSON is confidential or authenticated.

## Envelope

```json
{
  "messageType": 2,
  "payload": { "type": 2, "value": { "deltaX": 3, "deltaY": -1 } },
  "protocolVersion": 1,
  "sequence": 7,
  "sessionID": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
  "timestampMs": 1234
}
```

All integer fields use fixed-width Swift integer types. `sessionID` and audio
`streamID` are exactly 16 bytes. Text is explicitly UTF-8 bytes (maximum 2048
bytes). Each PCM chunk is a non-empty even-length byte sequence of at most
2048 bytes, sent as a base64 string, plus optional samplePosition and isLast. A decoded envelope is rejected before feature code sees it if
the input exceeds 8192 bytes, the declared byte-array count exceeds 2048, the
version/type is unknown, the payload type disagrees with the envelope, or a
numeric/format bound fails.

## Message table

| Type | Value | Delivery | Payload and bounds |
| --- | ---: | --- | --- |
| heartbeat | 1 | unreliable | active flag, button mask (`0x03`), modifier mask (`0x0f`), interval 100–1000 ms |
| pointer delta | 2 | unreliable | signed X/Y logical points, each within ±8192 |
| scroll delta | 3 | unreliable | signed X/Y scroll units, each within ±8192 |
| mouse button | 4 | reliable | left/right button and explicit up/down transition |
| text input | 5 | reliable | non-empty valid UTF-8, maximum 2048 bytes |
| hotkey | 6 | reliable | copy, paste, undo, redo, select all, escape, return, tab, or arrow action |
| motion pointer delta | 7 | unreliable | signed X/Y logical points ±8192, sample rate 1–100 Hz |
| audio chunk | 8 | unreliable | Live voice uses a binary PRA1 frame (IMA ADPCM) encrypted as this type. JSON audio chunks remain valid for tests. |
| acknowledgement | 9 | reliable | positive acknowledged sequence and accepted/duplicate/rejected status |
| connection status | 10 | reliable | disconnected/connecting/connected/authenticated/paused and numeric reason |
| error | 11 | reliable | fixed error code and retryable flag; no free-form text |
| ping | 12 | reliable | empty payload; phone-originated link check |
| pong | 13 | reliable | empty payload; Mac reply to ping |

Reliable state transitions are classified by `SequenceTracker`. A duplicate is
the same sequence as the last accepted one; an older sequence is out of order;
a forward jump is a gap and is accepted while surfaced to the caller. Sequence
zero is invalid. This classification is transport-neutral and does not itself
retry or acknowledge a message.

Unknown protocol versions and message types fail closed. Unknown enum values,
malformed JSON, truncated JSON, invalid UTF-8, and payload/type mismatches are
reported as deterministic protocol errors without including untrusted input in
error text.

The bounded decoder corpus can be rerun with
`./scripts/fuzz-protocol.sh`. It executes 2,000 deterministic byte inputs using
a fixed test seed and asserts that every failure remains a `ProtocolError`; the
bytes themselves are never logged.
