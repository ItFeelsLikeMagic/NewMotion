#!/bin/sh
set -eu

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/debug-mac.sh [path]

GET the Mac companion debug snapshot from the loopback server.
The default path is /state. Use /health for a liveness check.
HELP
    exit 0
fi

PATH_NAME="${1:-/state}"
case "$PATH_NAME" in
    /*) ;;
    *) PATH_NAME="/$PATH_NAME" ;;
esac

FILE="${PHONE_REMOTE_DEBUG_FILE:-/tmp/phoneremote-mac-debug.json}"
[ -f "$FILE" ] || { echo "error: debug server file not found at $FILE; is PhoneRemoteMac running?" >&2; exit 1; }
PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$FILE")
curl -fsS "http://127.0.0.1:${PORT}${PATH_NAME}"
echo
