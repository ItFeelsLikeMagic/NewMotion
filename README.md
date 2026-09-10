# NewMotion

Your iPhone as a trackpad, keyboard, and dictation mic for your Mac.

NewMotion is two apps. The one in your hand is a trackpad, an air mouse, a
keyboard, and a push-to-talk mic. The one on your Mac sits in the menu bar and
does the clicking and typing. They talk over Bluetooth LE, so nothing you do
passes through a server and there is no account to make.

Pair once by scanning a QR code. After that the phone reconnects on its own.

> [!NOTE]
> This is a prototype. It runs on real hardware and the automated suites are
> green, but the hardware checklist has never been run end to end. Expect
> rough edges.

## Install

**Mac companion.** Paste this into Terminal:

```sh
curl -fsSL https://itfeelslikemagic.github.io/NewMotion/install.sh | sh
```

It downloads the latest release, puts the app in Applications, and starts it.
Read [`install.sh`](install.sh) first if you would rather not pipe a script
into a shell.

By hand: download `NewMotion.dmg` from
[Releases](https://github.com/ItFeelsLikeMagic/NewMotion/releases), open it,
and drag NewMotion into Applications. A `NewMotion.zip` sits beside it with
the same app inside.

The app lives in the menu bar, not the Dock. On first launch it asks for two
permissions:

- **Bluetooth** to reach the phone.
- **Accessibility** to move the cursor and type.

It keeps itself current. Once a day it asks GitHub for a newer release and
applies it after two minutes with no phone connected, so an update never lands
mid-session. A release marked critical skips the wait. There is a **Check for
Updates** item in the menu.

**iPhone app.** Not on the App Store yet. Build it onto your own device:

```sh
./scripts/install-phone.sh
```

You need Xcode, a paired iPhone with Developer Mode on, and your own Apple
signing team.

Requires macOS 15 or later and iOS 18 or later. Dictation needs iOS 26, where
Apple's on-device speech engine lives.

## What it does

- **Trackpad.** Move, tap, drag, and two-finger scroll up and down.
- **Air mouse.** Turn it on in Settings, then point the phone and the cursor
  follows.
- **Keyboard.** Type on the phone, the text lands on the Mac.
- **Rub out text.** Hold a delete key and slide left to take back a character
  at a time, right to put it back. Slide up first and it works in whole words.
  A tap is still one delete.
- **Dictation.** Hold to talk. Apple's on-device speech turns it into text.
- **Word boosting.** The Mac reads the names and jargon showing in your front
  window and nudges dictation toward them, so a project's own vocabulary comes
  out spelled right.

## Privacy

One thing goes over the internet: once a day the Mac app asks GitHub whether
there is a newer release.

Everything else stays between your two devices over Bluetooth LE. No accounts,
no telemetry, no analytics, no crash reporting.

Speech is transcribed on the iPhone by Apple's own engine and the audio never
leaves it. Transcripts, typed text, and pointer paths are never written to a
log; the debug surfaces carry counts and states only. The Mac refuses to type
while macOS reports a secure input session, so nothing lands in a password
field. The word-boost walk stops there too.

The Mac app also opens a debug server on `127.0.0.1:18765`. It is loopback
only, so nothing reaches the network, but any process on your Mac can call it
and some of its routes press keys. `NEWMOTION_DEBUG_SERVER=0` turns it off.

Full policy: [NewMotion Privacy
Policy](https://itfeelslikemagic.github.io/NewMotion/privacy.html).

## Build it

```sh
./scripts/build.sh        # both apps and every test bundle
./scripts/test.sh         # shared and macOS suites
./scripts/install-mac.sh  # replaces the copy in /Applications and launches it
```

The Xcode project is generated from [`project.yml`](project.yml) and is not
checked in, so change that file and leave the `.xcodeproj` alone. Signing
values come from the environment and are never committed.

macOS ties the Accessibility grant to one app path and one signature. That is
why `install-mac.sh` writes to `/Applications`, and why opening a build from
`DerivedData` leaves you re-approving the grant forever.

Packaging, cutting a release, reading logs, and every
environment variable: [`scripts/README.md`](scripts/README.md). Each script
also takes `--help`.

## Layout

| Path | Contents |
| --- | --- |
| `iPhone/` | The app in your hand: capture, dictation, pairing, BLE client. |
| `Mac/` | The menu bar companion: input injection, word boosting, BLE peripheral. |
| `Shared/` | The wire protocol and the GATT contract both apps must agree on. |
| `Tests/` | Unit suites for the shared protocol, the Mac input path, and the phone. |
| `scripts/` | Build, install, package, release. Has its own [README](scripts/README.md). |

## When something is off

**The Mac app is running but the phone never finds it.** Check Bluetooth is
granted in System Settings, Privacy and Security. The Mac remembers every
phone you have paired and watches for all of them, but it holds one connection
at a time, so close the app on the other phone. A fresh `devicectl install`
can wipe the phone's trust store; scan the QR code again.

**The cursor moves but nothing types.** Accessibility is a separate grant.
Check it in the same panel, and make sure the app you launched is the one in
`/Applications`.

## Uninstall

1. Quit NewMotion from the menu bar.
2. Drag `/Applications/NewMotion.app` to the Trash.
3. Remove it in System Settings under Privacy and Security, in both
   Accessibility and Bluetooth.

Settings and the paired-phone records go with these:

```sh
defaults delete com.davidliao.newmotion.macos
security delete-generic-password -s com.davidliao.newmotion.macos.trusted-devices
```

## Contributing

Branch, commit, open a pull request against `main`. Run `./scripts/test.sh`
before you claim something works. [`CLAUDE.md`](CLAUDE.md) has the rules that
are not obvious from the code.

Updates are delivered by [Sparkle](https://sparkle-project.org).

## License

MIT. See [LICENSE](LICENSE).
