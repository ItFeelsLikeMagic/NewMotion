#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEVICE="${PHONE_REMOTE_DEVICE_NAME:-}"
if [ -z "$DEVICE" ]; then
    DEVICE="dliao's iPhone"
fi
DEST="${PHONE_REMOTE_PHONE_DEBUG:-/tmp/phoneremote-phone-debug}"
BUNDLE_ID="${PHONE_REMOTE_IOS_BUNDLE_ID:-com.example.phoneremote.ios}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/debug-phone.sh

Copy the iPhone app's privacy-safe debug log off the device. The files contain
camera/pairing state only. They do not include QR text, keys, or device ids.
HELP
    exit 0
fi

mkdir -p "$DEST"
copy_one() {
    src=$1
    out=$2
    xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$src" --destination "$out" >/dev/null 2>&1 || return 1
    return 0
}

if copy_one "Documents/phoneremote-debug-state.json" "$DEST/phoneremote-debug-state.json"; then
    echo "STATE"
    cat "$DEST/phoneremote-debug-state.json"
else
    echo "STATE_MISSING"
fi
if copy_one "Documents/phoneremote-debug.jsonl" "$DEST/phoneremote-debug.jsonl"; then
    echo "EVENTS"
    tail -40 "$DEST/phoneremote-debug.jsonl"
else
    echo "EVENTS_MISSING"
fi
