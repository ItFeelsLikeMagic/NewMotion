#!/bin/sh
set -eu

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/logs-mac.sh

Show the last NEWMOTION_LOG_WINDOW (default 5m) of local NewMotion
process logs using macOS Unified Logging. The command is read-only.
HELP
    exit 0
fi

command -v log >/dev/null 2>&1 || { echo "error: macOS log is required" >&2; exit 1; }
WINDOW="${NEWMOTION_LOG_WINDOW:-5m}"
log show --last "$WINDOW" --style compact --predicate 'process == "NewMotion" OR process == "NewMotion" OR senderImagePath CONTAINS[c] "NewMotion"'

