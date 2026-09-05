#!/bin/sh
set -eu

UDID="${IPHONE_UDID:-}"
BUNDLE_ID="${PHONE_REMOTE_IOS_BUNDLE_ID:-com.davidliao.phoneremote.ios}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: IPHONE_UDID=<device-identifier> ./scripts/launch-phone.sh [--udid ID]

Launch the installed Phone Remote iPhone app using devicectl.
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
xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID"

