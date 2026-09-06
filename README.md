# NewMotion

Your iPhone as a trackpad, air mouse, keyboard, and dictation mic for your Mac,
over Bluetooth LE. Pair once with a QR code and the phone drives the Mac.

Two apps: the iPhone app you hold, and a small Mac companion that lives in the
menu bar and does the clicking and typing. Nothing goes over the network and
nothing goes to a server. Speech is turned into text on the iPhone itself.

This is a working prototype, not a finished product. It is proven on real
hardware but has not been through its release checklist.

## What it does

- **Trackpad.** Move, tap, two-finger scroll, drag.
- **Air mouse.** Point the phone and the cursor follows.
- **Keyboard.** Type on the phone, the text lands on the Mac.
- **Rub out text.** Hold a delete key and slide left to erase a word at a
  time, right to bring it back. A tap is still one delete.
- **Dictation.** Hold to talk. Apple's on-device speech turns it into text.
- **Word boosting.** The Mac reads the names and jargon visible in your front
  window and nudges dictation toward them, so it spells your project's own
  words right. Skipped while a password field is focused.

## Install

**Mac companion, one line.** Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/ItFeelsLikeMagic/NewMotion/main/install.sh | sh
```

It downloads the latest release, refuses to go on unless Apple signed and
notarized it and the signature is ours, installs it into Applications, and
starts it. Read [`install.sh`](install.sh) first if you would rather not pipe a
script from the internet into a shell; that is a fair instinct.

**Mac companion, by hand.** Download `NewMotion.dmg` from
[Releases](https://github.com/ItFeelsLikeMagic/NewMotion/releases), open it, and
drag NewMotion into Applications. It is signed and notarized by Apple, so it
opens without a warning. It lives in the menu bar, not the Dock. Grant it
Accessibility access when asked; that is what lets it move your cursor and type.

There is a `NewMotion.zip` beside it holding the same notarized app, if you
would rather have a plain file. Either works. The disk image is the one to lead
with, because macOS mounts it itself and no unarchiver ever touches the app.

**It keeps itself up to date.** Once a day it asks GitHub whether there is a
newer release and downloads it quietly. It applies the update during a quiet
spell, once no phone has been connected for two minutes, so it never lands
mid-session. Usually that happens overnight and you never see it. That daily
question is the only thing this app ever sends over the internet. There is a
**Check for Updates** item in the menu if you would rather not wait.

If a Mac says Apple cannot verify the app, in order:

1. Open System Settings, Privacy and Security, and check **Allow applications
   from**. Set to **App Store**, a Mac turns down every app from outside the
   store however it is signed; it needs to say "App Store and known
   developers". Scroll down that same panel right after a refusal, where an
   "Open Anyway" button usually appears.
2. Check the Mac is on macOS 15 or later, and install any pending update.
3. Restart the Mac. The service that answers this question can wedge, and
   while it is wedged it turns down apps it should accept.

**iPhone app.** Not on the App Store yet. Build and install it yourself with
`./scripts/install-phone.sh` (needs Xcode, a paired iPhone with Developer Mode
on, and your own Apple signing team).

## Privacy

- No network. Everything travels over Bluetooth LE between your two devices.
- No accounts, no telemetry, no analytics.
- Speech is transcribed on the iPhone by Apple's on-device speech engine. Audio
  never leaves the phone.
- Transcripts, typed text, and audio are never written to a log. Debug output
  carries counts only.
- The Mac refuses to type anything while macOS reports a secure input session,
  so nothing is injected into a password field.

## Requirements

- macOS 15 or later, Apple silicon
- iOS 18 or later. Dictation needs iOS 26 or later, where Apple's on-device
  speech engine lives; everything else works on iOS 18.
- Xcode 27 to build. Developed against 27.0 beta and Swift 6.4.

## Build it

```sh
./scripts/build.sh   # both apps and every test bundle
./scripts/test.sh    # shared and macOS suites
```

The Xcode project is generated from [`project.yml`](project.yml) and is not
checked in, so change that file rather than the project. Signing values come
only from the environment and are never committed.

The Mac companion you click must live at `~/Applications/NewMotion.app`.
`./scripts/install-mac.sh` builds it, replaces that copy, and launches it. Do
not `open` a build from `/tmp` or `DerivedData`, or the Accessibility grant
will not follow the app.

Packaging a notarized copy, cutting a release, reading logs, and every
environment variable: [`scripts/README.md`](scripts/README.md). Each script
also takes `--help`.

## How it is put together

- `iPhone/`: the app you hold. Capture, dictation, pairing, and the BLE client.
- `Mac/`: the menu bar companion. Input injection, word boosting, and the BLE
  peripheral.
- `Shared/`: the wire protocol and the GATT contract both apps must match.
- `Config/` and `project.yml`: build settings and the generated Xcode project.
- `scripts/`: build, install, packaging, and releasing, with its own
  [README](scripts/README.md).
- `Tests/`: unit tests for the shared protocol and the Mac input path.
- [`CLAUDE.md`](CLAUDE.md): the rules a coding agent has to know before it
  changes anything here.

## License

MIT. See [LICENSE](LICENSE).
