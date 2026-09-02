# iPhone BLE Remote prototype

This repository contains the native iPhone/macOS prototype described in [`docs/iphone_ble_remote_mvp_scope.md`](docs/iphone_ble_remote_mvp_scope.md). The project file is text-defined in [`project.yml`](project.yml); the generated Xcode project is local-only and ignored by Git.

## Development loop

```sh
./scripts/generate.sh
./scripts/build.sh
./scripts/test.sh
# Optional bounded decoder corpus
./scripts/fuzz-protocol.sh
```

The scripts select a simulator or macOS destination for local checks and pass `CODE_SIGNING_ALLOWED=NO` unless a physical-device workflow explicitly supplies local signing settings. Use `--help` on each script for options.

Device install, launch, and log collection require a paired iPhone, Developer Mode, a locally configured signing team, and the `IPHONE_UDID` environment variable or `--udid` argument. The scripts validate those inputs before invoking `devicectl`; they never store credentials or device identifiers.

`install-phone.sh` keeps signing disabled by default. For a real device, set
`PHONE_REMOTE_SIGNING=1` and `PHONE_REMOTE_DEVELOPMENT_TEAM` in the local
environment (optionally `PHONE_REMOTE_CODE_SIGN_IDENTITY`); these values are
never committed.

The Mac companion you click must live at `~/Applications/PhoneRemoteMac.app`.
`./scripts/install-mac.sh` builds, replaces that copy, and launches only that
copy. Do not `open` a `/tmp` or DerivedData build. Use the same local signing
env vars so Accessibility stays on the signed app after rebuilds.

The only unavoidable GUI actions are Apple ID/team selection in Xcode, the iPhone trust prompt, Developer Mode, and any signing/device-registration repair. See [`docs/development_environment.md`](docs/development_environment.md) for the pinned toolchain and device matrix.

When resuming work, read [`docs/worker_learnings.md`](docs/worker_learnings.md)
and the append-only [`docs/implementation_progress.md`](docs/implementation_progress.md)
before changing project or transport behavior.
