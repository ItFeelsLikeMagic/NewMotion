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
[`project.yml`](../project.yml), never the `.xcodeproj`.

## Running it on your own devices

| Script | What it does |
| --- | --- |
| `install-mac.sh` | Builds the Mac companion and replaces `~/Applications/NewMotion.app`, then launches that copy. |
| `install-phone.sh` | Builds the iPhone app and installs it on a paired device with `devicectl`. |
| `launch-phone.sh` | Launches the app already on the phone. |

macOS ties the Accessibility grant to the exact app path and signature, so the
copy you click has to be the one in `~/Applications`. Never `open` a build from
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

## Shipping

| Script | What it does |
| --- | --- |
| `package-mac.sh` | Release build, Developer ID signature, hardened runtime, notarized by Apple, stapled. Writes `build/dist/NewMotion.dmg` and `NewMotion.zip`. |
| `release-mac.sh` | Packages, tags the commit, and publishes the GitHub release with both files attached. |

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
build.

## Environment

| Variable | Used by | What it is |
| --- | --- | --- |
| `NEWMOTION_DERIVED_DATA` | every build | Where DerivedData goes. Defaults to `DerivedData` in the repo. |
| `NEWMOTION_SIGNING` | install scripts | `1` turns on development signing. Off by default. |
| `NEWMOTION_DEVELOPMENT_TEAM` | install, package | Your ten-character Apple team id. |
| `NEWMOTION_CODE_SIGN_IDENTITY` | install, package | Overrides the certificate picked from your keychain. |
| `NEWMOTION_NOTARY_PROFILE` | package, release | The `notarytool` keychain profile name. |
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
