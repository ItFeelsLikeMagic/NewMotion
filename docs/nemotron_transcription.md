# The Nemotron transcription stack (removed)

Written the day it was removed, so the design is recoverable without reading a
diff. Nothing here describes current behaviour. Voice typing now runs on
Apple's on-device analyser on the phone; see `docs/status.md`.

## Why it was removed

It worked, and on the owner's voice it was good. It cost three local models on
the Mac and about 4.7 GB on disk:

| Model | Job | Size |
|---|---|---|
| `nvidia/nemotron-3.5-asr-streaming-0.6b` q8_0 GGUF | speech to text | 707 MB |
| `superwhisper/s1-mini` GGUF on Ollama | tidying the transcript | 1.5 GB |
| `qwen3:4b-instruct-2507-q4_K_M` on Ollama | spoken edits | 2.5 GB |

An App Store reviewer cannot install any of that. The Mac companion has to be
a download that works on its own, and these three models were the only thing
standing in the way. Apple's analyser is 0 MB in the app, needs no server, and
carries the same word-boosting idea the cache was built around.

So all three went, along with the audio wire that fed them. The word cache is
the one piece that survived, because it never depended on the recogniser: it
now travels to the phone instead of into a local WebSocket. The Mac companion
now runs no models at all.

### Spoken edits

Removed at the same time, for the same reason. Holding to talk and dragging
onto a pencil target turned the words into an instruction rather than text.
The Mac read the focused field, sent it plus the instruction to Qwen, and
applied the answer as Select All plus one insert, so a single Cmd+Z undid it.
The field was left alone when it was empty, unreadable, over 1,200 characters,
or unchanged by the model. Measured 0.2 to 0.8 s per edit once the model was
resident, about 3 s on the first. Known weakness: an instruction with two parts
was often only half applied. It was never verified on hardware beyond one
owner-run check. Its UI was `PushToTalkZone.editLeading/.editTrailing`, the
`spokenEditEnabled` setting, and the `.intent`/`.edit` stream flags.

## How it worked

### The wire

Audio left the phone as its own binary frame, not as a protocol envelope.

- `Shared/Protocol/VoiceStream.swift`: `VoiceStreamFrame`, magic `PRA1`, 32-byte
  big-endian header, payload capped at 2048 bytes. Header carried version,
  flags, codec, a 16-byte stream id, a `UInt32` sequence, a `UInt16` sample
  count and a `UInt16` payload length.
- `VoiceStreamFlags`: `.start` `.end` `.cancel` `.edit` `.intent`. A press sent
  `.start` before the microphone opened so the Mac could open its recogniser
  during the audio session warm-up. A release sent `.end`, a drag into a trash
  target sent `[.end, .cancel]`, a drag into a pencil target sent `[.end, .edit]`,
  and leaning either way mid-hold sent a zero-sample `[.intent]` frame.
- `Shared/Protocol/IMAADPCM.swift`: 4:1 IMA ADPCM. 640-sample chunks, 40 ms at
  16 kHz mono, produced by `PCM16Chunker`.
- Frames were sealed as `MessageType.audioChunk` (code 8, unreliable delivery)
  and sent on the data channel; only the `.end` frame went reliable.
- `iPhone/Audio/VoiceUplink.swift` did the encode, seal and hop to main.

### The Mac side

- `Mac/PhoneRemoteMacApp.swift` sniffed the `PRA1` magic before protocol
  decoding and handed the frame to `VoicePTTCoordinator`.
- `Mac/Transcription/VoicePTTCoordinator.swift` owned one `Utterance` per
  stream: decode ADPCM, stream PCM as it arrived, commit on `.end` or after
  1.5 s of silence, hold an edit hint for 3 s, and type finals in start order.
- `Mac/Transcription/NemotronRealtime.swift` health-checked `nemo-speech serve`
  on `PHONE_REMOTE_NEMO_PORT` (default 18766) at launch, spawned
  `~/.local/bin/nemo-speech` with the GGUF from the Hugging Face hub cache and
  `--device metal`, logged to `/tmp/phoneremote-nemo-speech.log`, and stopped
  the child on quit. Each utterance was one `/v1/realtime` WebSocket.
- `Mac/Transcription/S1MiniNormalizer.swift` posted the raw transcript to
  Ollama `/api/generate` with `raw: true`, 5 s timeout, and fell back to the
  raw text on any failure.

### Boosting, which is the part that survived

The recogniser was told what to listen for before any audio reached it:

```json
{"type":"session.update","session":{"sample_rate":16000,
 "speech_contexts":[{"phrases":["..."],"boost":3.0}]}}
```

`boost` was clamped at 5 by that recogniser and 3.0 was its documented working
value. One strength applied to the whole list; there was no per-phrase weight.
The list itself came from `Mac/Transcription/ScreenVocabulary.swift`, which is
**still in use** and is now pushed to the phone instead. Its behaviour is
unchanged: an Accessibility walk of the front window, candidates filtered
against the system spell checker, a cache with a 600 s lease that extends to
three hours once a phrase is actually heard, capacity 400, output capped at 40.

The one timing detail worth keeping in mind: `speechContextTimeout` was 0.3 s.
The session raced the vocabulary lookup against that deadline and went out
unboosted rather than holding the start of a sentence. The phone-side design
has no such race, because the list is pushed ahead of the press rather than
fetched during it.

## What it measured

From the last recorded run on the owner's Mac, in the `/state` snapshot as
`audioTiming`:

```
asr 215 / read 12 / norm 5009 / type 0 = 5236 ms
```

`asr` is the recogniser, `read` the focused-field read, `norm` the S1-mini
tidy, `type` the injection. S1-mini was by a wide margin the slowest stage and
the least valuable, since Apple's analyser punctuates on its own. Nemotron
itself at 215 ms was never the problem.

Earlier figures in `docs/latency.md`: final text landed roughly 700 ms after
commit for real speech, and the Mac padded 400 ms of silence before committing.

## Known weaknesses at the time of removal

- Every gate in `docs/verification/gate-f-audio.md` was `NOT RUN`. There was no
  five-minute soak, no WAV inspection, and no concurrent pointer-latency
  measurement.
- `audioMerge` frequently reported `caretNotAtEnd`, refusing to type when the
  caret was not at the end of the field.
- S1-mini was measured at 5 s on a cold model.
- The whole path was dead if the user had not installed Ollama and pulled two
  models by hand, which no reviewer and no ordinary user would ever do.

## Restoring it

Everything is in history. Find the removal and take the files back:

```sh
git log --diff-filter=D --oneline -- Mac/Transcription/NemotronRealtime.swift
git checkout <that-commit>^ -- Mac/Transcription Shared/Protocol/VoiceStream.swift \
    Shared/Protocol/IMAADPCM.swift iPhone/Audio/VoiceUplink.swift \
    scripts/install-s1-mini.sh
```

`scripts/install-s1-mini.sh` registered the normalizer with Ollama and was
removed alongside. The Nemotron GGUF was never in the repo; it came from the
Hugging Face hub cache and is pulled with:

```sh
huggingface-cli download nvidia/nemotron-3.5-asr-streaming-0.6b \
    nemotron-3.5-asr-streaming-0.6b.q8_0.gguf
```

Restoring the stack also means restoring `MessageType.audioChunk` and the
`PRA1` sniff in `Mac/PhoneRemoteMacApp.swift`, or the frames will decode as
ordinary envelopes and be refused. Restoring spoken edits additionally means
bringing back the pencil zones on the phone and the `.intent`/`.edit` flags,
which is most of `iPhone/Audio/PushToTalkDragZones.swift` as it stood then.
