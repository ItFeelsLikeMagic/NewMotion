# NewMotion

Your iPhone as a trackpad, keyboard, and dictation mic for your Mac.

NewMotion is two apps. The one in your hand is a trackpad, an air mouse, a
keyboard, and a push-to-talk mic. The one on your Mac sits in the menu bar and
does the clicking and typing. They talk over Bluetooth LE, so nothing you do
passes through a server and there is no account to make.

Pair once by scanning a QR code. After that the phone reconnects on its own.

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


**iPhone app**
[Join the TestFlight to use the mobile app.](https://testflight.apple.com/join/Jg63TXgn)

## What it does

- **Trackpad.** Move, tap, drag, and two-finger scroll up and down.
- **Air mouse.** Turn it on in Settings, then point the phone and the cursor
  follows.
- **Keyboard.** Type on the phone, the text lands on the Mac.
- **Dictation.** Hold to talk. Apple's on-device speech turns it into text.

## Privacy
Everything stays between your two devices over Bluetooth LE.

Speech is transcribed on the iPhone by Apple's own engine and the audio never
leaves it. Transcripts, typed text, and pointer paths are never written to a
log. The Mac refuses to type while macOS reports a secure input session, so 
nothing lands in a password field.

Full policy: [NewMotion Privacy
Policy](https://itfeelslikemagic.github.io/NewMotion/privacy.html).

## Build it

```sh
./scripts/build.sh        # both apps and every test bundle
./scripts/test.sh         # shared and macOS suites
./scripts/install-mac.sh  # replaces the copy in /Applications and launches it
```

The Xcode project is generated from [`project.yml`](project.yml) and is not
checked in, so change that file and leave the `.xcodeproj` alone.

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

## Uninstall

1. Quit NewMotion from the menu bar.
2. Drag `/Applications/NewMotion.app` to the Trash.
3. Remove it in System Settings under Privacy and Security, in both
   Accessibility and Bluetooth.

## Contributing

Branch, commit, open a pull request against `main`. Run `./scripts/test.sh`
before you claim something works. [`CLAUDE.md`](CLAUDE.md) has the rules that
are not obvious from the code.

Updates are delivered by [Sparkle](https://sparkle-project.org).

## License

MIT. See [LICENSE](LICENSE).
