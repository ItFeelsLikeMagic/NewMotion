# Gate F — Voice-path verification

Status: **NOT RUN as a measured run**. The path works in daily use, but no
timed, recorded run against the criteria below exists.

The path this gate covers changed on 2026-09-06. Speech is turned into text on
the iPhone by Apple's `SpeechAnalyzer`; only the finished sentence crosses, as
a `spokenText` message. No audio travels, so there is nothing to reassemble and
no gap accounting to check. What replaced those checks: the sound stays on the
phone, the text arrives whole, and boosting reaches the recogniser before the
first buffer.

## Automated evidence

`PHONE_REMOTE_RUN_IOS_TESTS=1 ./scripts/test.sh` covers local-press-only
capture, stop on release, cancel dropping the utterance, boost-list parsing and
merging, splitting a long sentence at 1 KB without breaking a grapheme cluster,
the `vocabulary` and `spokenText` payload bounds, and the word cache's leases.
No audio, transcript, or recording is stored in the repository.

## Physical procedure

1. On the iPhone, open Settings and confirm Status reads Ready. On a fresh
   install it reads a download percentage first; wait for it.
2. Click a Mac text field. Hold Push to Talk, speak a sentence containing a
   name from the Mac's front window, and release. The sentence appears, with
   the name spelled correctly.
3. Repeat with the phone's Wi-Fi and cellular off. The result must be
   identical: nothing in this path uses the network.
4. Hold, speak, and drag to a cancel corner before releasing. Nothing is typed.
5. Hold for five minutes of continuous speech and release. The whole passage
   arrives in order, in 1 KB pieces.
6. Focus a password field and speak. Nothing is typed, and the Mac reports
   "Spoken text held back".
7. Check `./scripts/debug-phone.sh` for `ondevice_typed` with a character
   count, and confirm no event anywhere carries the words themselves.

## Result template

### Run YYYY-MM-DD HH:MM TZ

- iPhone model / iOS build: `TBD`
- Mac model / macOS build: `TBD`
- Build identifier: `TBD`
- Model status at start: `TBD` (required: Ready)
- Press to first words on screen: `TBD ms`
- Release to text landing: `TBD ms`
- Boosted name transcribed correctly: `TBD`
- With the network off: `TBD`
- Five-minute passage, pieces and order: `TBD`
- Cancel corner typed nothing: `TBD`
- Secure field refused: `TBD`
- Concurrent pointer p95 latency: `TBD ms` (limit: 50 ms)
- Result: `PASS` / `FAIL` / `BLOCKED`
- Notes/remediation tickets: `TBD`
