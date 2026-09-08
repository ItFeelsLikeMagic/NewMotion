# Scripts

Every script here is POSIX `sh`, takes `--help`, and reads its settings from
the environment. Nothing about signing is ever written into the repository.

Read this file when you need the toolchain. The [top-level README](../README.md)
is for people using the app; this one is for people building it.

## Everyday

| Script | What it does |
| --- | --- |
| `generate.sh` | Writes `NewMotion.xcodeproj` from [`project.yml`](../project.yml). Every script that builds runs this first, so you rarely call it yourself. |
| `build.sh` | Builds both apps and all test bundles, signing off. |
| `test.sh` | Runs the shared and macOS suites. The macOS test host runs inert: no Bluetooth, no Keychain, no speech, so a run never raises a system prompt. |
| `fuzz-protocol.sh` | Runs the fixed-seed decoder corpus. Logs no input bytes. |

The Xcode project is generated and not checked in. Change
[`project.yml`](../project.yml), never the `.xcodeproj`. `generate.sh` needs
XcodeGen (`brew install xcodegen`).

## Running it on your own devices

| Script | What it does |
| --- | --- |
| `install-mac.sh` | Builds the Mac companion and replaces `/Applications/NewMotion.app`, then launches that copy. |
| `install-phone.sh` | Builds the iPhone app and installs it on a paired device with `devicectl`. This is how a phone gets a test build; TestFlight is not. |
| `launch-phone.sh` | Launches the app already on the phone. |

macOS ties the Accessibility grant to the exact app path and signature, so the
copy you click has to be the one in `/Applications`, the same path the
public installer uses. Never `open` a build from
`/tmp` or `DerivedData`. Set `NEWMOTION_SIGNING=1` and
`NEWMOTION_DEVELOPMENT_TEAM` for the local install, or the grant is dropped on
every rebuild and you re-approve it each time.

## Looking at what it did

| Script | What it does |
| --- | --- |
| `debug-mac.sh` | GETs the Mac companion's debug snapshot from its loopback server. `/state` by default, `/health` for liveness. |
| `debug-phone.sh` | Copies the phone's privacy-safe debug log off the device. |
| `logs-mac.sh` | Recent NewMotion lines from macOS Unified Logging. Read only. |
| `logs-phone.sh` | Collects an iPhone sysdiagnose with `devicectl`. Takes minutes. |

Nothing here can print a transcript, a keystroke, or audio. The debug surfaces
carry counts and states only, on purpose.

## Finding the notary profile again

`notarytool` keeps its credentials in the data protection keychain, which the
`security` command cannot read at all. `security dump-keychain` and
`security find-generic-password` both come back empty whether or not a profile
exists, so neither is evidence of anything. Ask `notarytool` instead:

```sh
xcrun notarytool history --keychain-profile phoneremote
```

A name that does not exist answers "No Keychain password item found for
profile". A real one returns submission history. The profile on David's Mac is
`phoneremote`, named before the app was, and it does not sync between Macs: a
new machine needs `notarytool store-credentials` run on it once.

## Shipping

| Script | What it does |
| --- | --- |
| `package-mac.sh` | Release build, Developer ID signature, hardened runtime, notarized by Apple, stapled. Writes `build/dist/NewMotion.dmg` and `NewMotion.zip`. |
| `release-mac.sh` | Packages, writes the Sparkle update feed, tags the commit, and publishes the GitHub release with all three files attached. `--critical` marks a release users are asked to install now. |
| `testflight-phone.sh` | Archives the iPhone app, signs it for distribution, and uploads it to TestFlight. `--dry-run` writes `build/dist/NewMotion.ipa` and uploads nothing. |

The whole release, once your changes are on main:

```sh
# 1. bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml, merge that
# 2. pull main, then:
./scripts/test.sh
./scripts/release-mac.sh
```

`release-mac.sh` reads the version from `project.yml` and never edits it. It
refuses to publish unless the commit is `origin/main`, the tree is clean, and
the tag is new. `--dry-run` builds the files and publishes nothing.
`--notes <file>` ships written release notes; without it GitHub lists the
commits, which is thinner than the install help the last release carried.

[`install.sh`](../install.sh) installs from the newest release's
`NewMotion.dmg`, so publishing the release is the step that hands people the
build. The one-liner people paste points at
`https://itfeelslikemagic.github.io/NewMotion/install.sh`, a copy that
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) republishes
whenever the root `install.sh` changes on `main`. Edit the root copy only.

The iPhone app ships to other people through TestFlight instead, because Apple
allows nothing else. Uploading is a release, not a way to try a change: it goes
to Apple and to every tester, so run it only when someone asks for a TestFlight
build by name. Putting a build on your own phone is `install-phone.sh`, above.

On a Mac signed in to Xcode the upload is the whole command:

```sh
NEWMOTION_DEVELOPMENT_TEAM=4B8P47VZGT ./scripts/testflight-phone.sh
```

App Store Connect refuses a build number it has already accepted for a
version, so a second upload of the same version needs `--build N` with a
higher number, or a bump in `project.yml`. The reviewer has only a phone and
the app does nothing alone, so external testing and App Review both need the
Mac companion's download link in the notes.

The `NEWMOTION_ASC_*` variables are for a build machine with no Xcode account.
Set all three or none.

## Updates

Installed copies update themselves. Sparkle reads `appcast.xml` from the newest
release once a day and downloads the new build quietly. Applying needs no
network: the notarization ticket is stapled into the file.

Sparkle installs on quit, and nobody quits a menu bar app, so the timing is
taken over in [`SoftwareUpdateController`](../Mac/Updates/SoftwareUpdateController.swift).
A staged build is held until no phone has been authenticated for two minutes,
then installs and relaunches silently. Two minutes rather than none so that
walking out of Bluetooth range and back does not relaunch the app mid-use.

Two things decide whether anyone is offered a build:

- `CURRENT_PROJECT_VERSION` has to go up. Sparkle compares that, not
  `MARKETING_VERSION`, which is only what people read.
- The release has to carry the same Developer ID. A signature from anywhere
  else installs and then loses the Accessibility grant.

`release-mac.sh` builds the feed with `generate_appcast`, which ships inside the
Sparkle package under `DerivedData/SourcePackages/artifacts`. It signs the feed
with an EdDSA key kept in your login Keychain under `https://sparkle-project.org`.
Lose that key and installed copies stop accepting updates until you publish a
build carrying a new public key. A copy is in 1Password. To write it out again,
on this machine or another, and never inside this tree, which is synced:

```sh
generate_keys -x ~/sparkle-private-key.txt   # delete it once it is stored
```

The matching public key is `SUPublicEDKey` in
[`Config/Mac-Info.plist`](../Config/Mac-Info.plist).

## Environment

| Variable | Used by | What it is |
| --- | --- | --- |
| `NEWMOTION_DERIVED_DATA` | every build | Where DerivedData goes. Defaults to `DerivedData` in the repo. |
| `NEWMOTION_SIGNING` | install scripts | `1` turns on development signing. Off by default. |
| `NEWMOTION_DEVELOPMENT_TEAM` | install, package | Your ten-character Apple team id. |
| `NEWMOTION_CODE_SIGN_IDENTITY` | install, package | Overrides the certificate picked from your keychain. |
| `NEWMOTION_NOTARY_PROFILE` | package, release | The `notarytool` keychain profile name. On David's Mac it is `phoneremote`, after the app's old name. |
| `NEWMOTION_ASC_KEY_ID` | `testflight-phone.sh` | Optional. The App Store Connect API key id. |
| `NEWMOTION_ASC_ISSUER_ID` | `testflight-phone.sh` | Optional. The issuer id that key belongs to. |
| `NEWMOTION_ASC_KEY_PATH` | `testflight-phone.sh` | Optional. Path to the `AuthKey_*.p8` file. Apple lets you download it once; keep it out of this repo. Without these three, the upload goes out as whoever is signed in to Xcode. |
| `IPHONE_UDID` | phone scripts | The device to install to, launch, or pull logs from. `--udid` does the same. |
| `NEWMOTION_RUN_IOS_TESTS` | `test.sh` | `1` also runs the iOS suite on a simulator. |
| `NEWMOTION_KEYCHAIN_TESTS` | `test.sh` | `1` runs the tests that use the real Keychain and prompt you. |

This tree lives in a synced folder, whose file provider stamps
`com.apple.FinderInfo` back onto files as fast as you clear it. That breaks
`codesign` and some test runs from the default DerivedData path. When a signed
build or a test run fails for a reason that makes no sense, put DerivedData
outside the tree:

```sh
NEWMOTION_DERIVED_DATA=/tmp/newmotion ./scripts/test.sh
```

`package-mac.sh` already works around this by staging and signing in a
temporary directory.
