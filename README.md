# iPhone BLE Remote prototype

Native iPhone and macOS prototype: the phone acts as a trackpad, air mouse, keyboard, and push-to-talk mic for the Mac over Bluetooth LE, after a one-time QR pairing. The scope is in [`docs/iphone_ble_remote_mvp_scope.md`](docs/iphone_ble_remote_mvp_scope.md).

The project file is text-defined in [`project.yml`](project.yml). The generated Xcode project is local-only and ignored by Git.

## Start here

Read these in order when picking the project up:

1. [`docs/status.md`](docs/status.md): what is built, what is proven on real hardware, the ticket backlog, and the traps that cost time before.
2. [`docs/worker_learnings.md`](docs/worker_learnings.md): the rules and invariants. Do not change project, transport, pairing, or safety behavior without reading it.
3. [`docs/development_environment.md`](docs/development_environment.md): pinned toolchain, device, env vars, and the exact commands for tests, device install, launch, and log pull.

Contracts that code must match:

- [`docs/protocol_v1.md`](docs/protocol_v1.md): shared wire protocol.
- [`docs/ble_gatt_contract.md`](docs/ble_gatt_contract.md): GATT service and byte framing.

Postmortems:

- [`docs/postmortem_camera_black_preview.md`](docs/postmortem_camera_black_preview.md): a day lost to a black QR camera that was the phone, not the app. Read it before touching the scanner.

## Development loop

```sh
./scripts/generate.sh
./scripts/build.sh
./scripts/test.sh
# Optional bounded decoder corpus
./scripts/fuzz-protocol.sh
```

The scripts select a simulator or macOS destination and pass `CODE_SIGNING_ALLOWED=NO` unless a physical-device workflow supplies local signing settings. Use `--help` on each script.

Device install, launch, and log collection need a paired iPhone, Developer Mode, a local signing team, and `IPHONE_UDID`. Signing values come only from the environment and are never committed. The exact commands, including the bundle-id prefix the installed phone build uses, are in [`docs/development_environment.md`](docs/development_environment.md).

The Mac companion you click must live at `~/Applications/PhoneRemoteMac.app`. `./scripts/install-mac.sh` builds, replaces that copy, and launches it. Do not `open` a `/tmp` or DerivedData build, or Accessibility permission will not follow the app.

The only unavoidable GUI actions are Apple ID and team selection in Xcode, the iPhone trust prompt, Developer Mode, and signing or device-registration repair.
