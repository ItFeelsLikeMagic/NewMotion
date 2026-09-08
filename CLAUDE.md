# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

An iPhone app and a Mac menu bar companion that let the phone drive the Mac
over Bluetooth LE. Three source roots:

- `iPhone/` the app you hold: capture, dictation, pairing, BLE client.
- `Mac/` the companion: input injection, word boosting, BLE peripheral.
- `Shared/` the wire protocol, crypto, and transport both sides must agree on.
  A change here is a change to both apps at once.
- `Tests/Shared`, `Tests/macOS`, `Tests/iOS` mirror those.

## Commands

Use the scripts. They generate the Xcode project first, so a raw `xcodebuild`
against a stale project is the usual reason something "does not compile".

```sh
./scripts/build.sh          # both apps and every test bundle
./scripts/test.sh           # shared and macOS suites
./scripts/install-mac.sh    # the Mac copy you actually click
```

[`scripts/README.md`](scripts/README.md) is the full map: every script, the
environment variables, the release flow, and the traps. Read it when the task
touches building, installing, packaging, or releasing. Each script also takes
`--help`.

## Rules that are not obvious from the code

- **The Xcode project is generated.** Edit [`project.yml`](project.yml) and run
  `./scripts/generate.sh`. Never edit `NewMotion.xcodeproj`; it is not checked
  in. Sources are picked up by directory, so a new file needs no project edit,
  only a regenerate, which every build script does for you. Needs XcodeGen:
  `brew install xcodegen`.
- **Swift 6, strict concurrency complete.** Both apps. Assume main-actor
  isolation and no implicit hops.
- **One thing goes over the network, and it is the updater.** Sparkle asks
  GitHub once a day whether there is a newer release, and applies it only
  during a stretch with no phone on the link. That is the whole list.
  BLE carries everything between the two devices. No accounts, no telemetry,
  no crash reporting, nothing about what anyone typed or pointed at. Do not
  add a second thing that phones home.
- **Nothing logs content.** No transcripts, keystrokes, pointer paths, QR text,
  or keys, in any log or debug surface. Counts and states only.
- **Every injected event goes through `SafeInputInjector`.** It re-checks
  Accessibility and the safety policy before each command and releases held
  buttons on any doubt. Do not post a `CGEvent` from anywhere else.
- **Typing stops at a password field.** `SecureInput.isActive()` gates both
  injection and the word-boost walk. Keep it that way.
- **Accessibility is tied to the exact app path and signature.** Only the copy
  in `/Applications` is trusted, and an unsigned rebuild drops the grant.
  That is the path `install.sh` ships to, so `install-mac.sh` writes there too.
  This is also why every release has to carry the same Developer ID: an update
  that swaps the app in place keeps the grant only if the signature matches.
- **The iPhone app ships only through TestFlight.**
  `./scripts/testflight-phone.sh` archives, signs, and uploads in one command.
  Do not hand-roll `xcodebuild archive`; two traps are already handled there.
  Automatic signing picks the identity itself, so naming `Apple Distribution`
  makes it refuse the build outright. And App Store Connect rejects a build
  number it has already accepted, so a second upload of one version needs
  `--build N` or a bump in `project.yml`.

## The hot path

Cursor and scroll packets arrive on the main actor about sixty times a second
and are applied there. Anything you add to message handling, input injection,
or the screen-reading walk runs between two frames of someone's cursor. No
synchronous I/O, no blocking calls, no per-packet work that rebuilds published
state. When something has to be slow, it belongs on a timer or a thread, not on
the packet.

## Working here

- Branch, commit, open a PR against `main`. `main` is squash-merged.
- Comments carry what the code cannot say: why, not what. Match the tone that
  is already there.
- Run `./scripts/test.sh` before you claim something works.
