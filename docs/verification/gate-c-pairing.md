# Gate C — QR pairing and authenticated-session verification

Status: **automated implementation verified; physical scan pending camera
permission and an interactive Mac/iPhone pairing run**. The signed iPhone app
installs and launches on the paired target.

## Automated attack matrix

Run the focused pairing tests through the normal test command. The latest
scripted run includes the shared BLE/pairing integration tests and passed with
0 failures. Every case must
record only the outcome and error class; never record the QR string, secret,
public/private key bytes, ciphertext, or plaintext content.

| Case | Expected result | Observed result |
| --- | --- | --- |
| Valid token, one confirmation | one authenticated session | `TBD` |
| Modified display name | reject before advertising | `TBD` |
| Modified pairing ID | reject before advertising | `TBD` |
| Modified public key / invalid key material | reject before advertising | `TBD` |
| Wrong one-time secret | handshake fails closed | `TBD` |
| Unknown token version | reject before advertising | `TBD` |
| Malformed, oversized, or non-canonical encoding | reject before advertising | `TBD` |
| Expiry at boundary and after expiry | reject | `TBD` |
| Replacement of an active token | prior token rejects | `TBD` |
| Concurrent/repeated token use | at most one success | `TBD` |
| Replay of a used token | reject; no trust record | `TBD` |
| Modified ciphertext/tag | reject; receive sequence unchanged | `TBD` |
| Replayed envelope | reject | `TBD` |
| Sequence rollback | reject | `TBD` |
| Role reflection / wrong peer identity | reject | `TBD` |
| Unknown or revoked trusted reconnect | reject | `TBD` |
| Corrupt/missing Keychain record | fail closed and removable | `TBD` |
| Scanner cancel / app transition | no advertising or trust | `TBD` |
| Secret/key/plaintext sentinel search in logs | no matches | `TBD` |

## Physical procedure

1. On the Mac, issue one QR offer with a visible expiry countdown (120 seconds
   maximum) and confirm replacement/cancel behavior.
2. On the foreground iPhone, grant camera permission, scan the offer, verify
   only the sanitized Mac display name and expiry are previewed, then cancel
   once and confirm once in separate runs.
3. Verify the BLE advertising path starts only after the explicit confirmation.
4. Complete the authenticated handshake and record the safe connected state.
5. Quit/relaunch or disconnect/reconnect both apps. Verify reconnect performs a
   fresh ephemeral handshake against the stored peer identity without QR.
6. Revoke trust on each side and verify reconnect is rejected until a new QR
   pairing.

## Result template

### Run YYYY-MM-DD HH:MM TZ

- iPhone model / iOS build: `TBD`
- Mac model / macOS build: `TBD`
- Start/end timestamps: `TBD`
- Token lifetime configured: `TBD` (must be ≤120 seconds)
- Confirmation count for successful run: `TBD` (must be exactly one)
- Valid pair / reconnect / revoke outcomes: `TBD / TBD / TBD`
- Attack matrix: `PASS` / `FAIL` / `BLOCKED`
- Log sentinel search: `TBD` (must have zero secret/key/plaintext matches)
- Evidence/log path (redacted aggregate only): `TBD`
- Notes/blockers: `TBD`

The current known hardware blocker is the missing interactive camera/BLE run
and redacted evidence capture. This does not waive the automated parser,
handshake, replay, trust-store, and redaction evidence requirements.
