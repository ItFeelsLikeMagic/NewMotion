# Development environment

This prototype is pinned to the following toolchain and test matrix. The values describe the environment used to validate the foundation on 2026-09-02; update this document with a ticket when the pin changes.

## Pinned inputs

| Input | Pin | Notes |
| --- | --- | --- |
| Xcode | 27.0 beta, build `27A5252f` | Use the selected full-Xcode developer directory configured on the validation host; its local filesystem path is intentionally not part of the project contract. |
| Swift | 6.4 (`swiftlang-6.4.0.33.1`) | Supplied by the pinned Xcode toolchain. |
| XcodeGen | 2.38.0 or newer compatible with `project.yml` | `xcodegen` was not installed on the validation host. `scripts/generate.sh` uses the checked-in fallback generator until XcodeGen is installed. Exact XcodeGen version remains **TBD** (owner: foundation maintainer; blocking ticket: FND-002 follow-up). |
| iOS deployment target | 18.0 | Chosen to keep the prototype below the current test OS while retaining current Core Bluetooth/Motion APIs. Revisit only with a target-matrix ticket. |
| macOS deployment target | 15.0 | Same policy as the iOS target. |
| Bundle-ID prefix | `com.example.phoneremote` | Placeholder development prefix only; the signing team must select a real prefix locally. Never commit a team ID or signing identity. |

## Target device matrix

| Role | Target | OS | Status |
| --- | --- | --- | --- |
| iPhone | iPhone 15 Pro Max (iPhone16,2) | iOS 27.0, build `24A5380h` | Owner enabled Developer Mode and restarted; DDI is compatible/usable, and the signed app installs/launches with the local Apple Development team. |
| Mac | Apple-silicon MacBook Pro (MacBookPro18,2, M1 Max) | macOS 27.0, build `26A5388g` | Host used for CLI builds and unit tests. |

The physical iPhone's UDID, serial number, Apple ID, team ID, and signing material are intentionally omitted. Supply a local `IPHONE_UDID` only when running device scripts.

## CLI versus GUI steps

### CLI-only steps

These are the repeatable commands exposed by the repository scripts:

```sh
./scripts/generate.sh
./scripts/build.sh
./scripts/test.sh
./scripts/install-phone.sh --udid "$IPHONE_UDID"
./scripts/launch-phone.sh --udid "$IPHONE_UDID"
./scripts/logs-phone.sh --udid "$IPHONE_UDID"
./scripts/logs-mac.sh
```

Voice typing streams compressed audio over BLE. The Mac helper starts a local
`nemo-speech serve` realtime socket and S1-mini. Override with
`PHONE_REMOTE_STT_ROOT`, `PHONE_REMOTE_NEMO_PORT`, `PHONE_REMOTE_STT_PYTHON`, or
`PHONE_REMOTE_TRANSCRIBE` if those paths move. Do not log transcripts.

The scripts do not create signing identities, provision profiles, Apple IDs, or credentials. Build/test defaults disable signing for local simulator/macOS checks; a physical device run requires a developer-selected team/signing identity in an untracked local override.

### Unavoidable Apple GUI steps

- Sign into Xcode with the developer's Apple ID and select the development team in the local project settings. The Apple ID and team ID must never be committed.
- On first connection, approve the iPhone's “Trust This Computer” prompt and enter the device passcode.
- Enable Developer Mode in **Settings → Privacy & Security → Developer Mode** on the iPhone, then confirm the reboot prompt. This was completed for the current target; keep the phone unlocked while validating DDI services.
- If Xcode reports a signing or device-registration issue, resolve it in Xcode's Accounts/Signing UI; do not weaken the CLI scripts or commit provisioning artifacts.
- Use Xcode's debugger only for occasional device-specific diagnosis; normal generation, build, tests, install, launch, and log collection remain scriptable.

## Open uncertainties

- **TBD — exact XcodeGen release:** owner: foundation maintainer; blocking ticket: FND-002 follow-up. Until pinned, the fallback generator is the reproducible path.
- **TBD — production bundle prefix:** owner: project owner; blocking ticket: target-matrix review after Gate A. A local development team is configured for the current physical smoke test, but the placeholder prefix is not a distribution identity.
- **TBD — final minimum OS versions:** owner: project owner; blocking ticket: target-matrix review after Gate A. The current 18.0/15.0 values are prototype build inputs, not a distribution promise.

## Latest capability probe

On 2026-09-02, after the owner enabled Developer Mode and restarted, the
latest `xcrun devicectl list devices` probe saw the target physical iPhone as
**available (paired)** and `device info ddiServices` reported compatible,
usable DDI content. Xcode local signing was configured, a target-specific
signed build installed successfully, and `launch-phone.sh` left the app process
running. `logs-phone.sh` remains blocked by Xcode 27's generic
`CoreDeviceCLISupport.DiagnoseError error 0`; a second physical phone was
unavailable. Simulator runtimes were available for iPhone 17, iPhone 17 Pro,
iPhone 17 Pro Max, iPhone 17e, and iPhone Air on iOS 27.0. Device identifiers
are intentionally omitted.
