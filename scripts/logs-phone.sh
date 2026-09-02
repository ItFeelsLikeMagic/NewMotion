#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
UDID="${IPHONE_UDID:-}"
OUTPUT="${PHONE_REMOTE_PHONE_LOG_OUTPUT:-$ROOT_DIR/phone-logs/sysdiagnose-$(date +%Y%m%d-%H%M%S)}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: IPHONE_UDID=<device-identifier> ./scripts/logs-phone.sh [--udid ID]

Collect a local iPhone sysdiagnose archive with devicectl. Set
PHONE_REMOTE_PHONE_LOG_OUTPUT to choose the destination directory. Collection
may take several minutes and requires a paired/trusted device.
HELP
    exit 0
fi

if [ "${1:-}" = "--udid" ]; then
    [ "$#" -ge 2 ] || { echo "error: --udid requires a value" >&2; exit 2; }
    UDID=$2
    shift 2
fi
[ "$#" -eq 0 ] || { echo "error: unknown argument: $1" >&2; exit 2; }
[ -n "$UDID" ] || { echo "error: set IPHONE_UDID or pass --udid before invoking devicectl" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || { echo "error: xcrun is required" >&2; exit 1; }
mkdir -p "$OUTPUT"
xcrun devicectl device sysdiagnose --device "$UDID" --destination "$OUTPUT"
echo "iPhone diagnostics written under $OUTPUT"

