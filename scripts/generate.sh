#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/generate.sh

Generate NewMotion.xcodeproj from project.yml. XcodeGen is preferred; when
it is not installed, the checked-in deterministic Python fallback is used.
The generated project is ignored by Git.
HELP
    exit 0
fi

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec "$ROOT_DIR/project.yml"
    echo "Generated NewMotion.xcodeproj with XcodeGen"
else
    command -v python3 >/dev/null 2>&1 || {
        echo "error: xcodegen is unavailable and python3 is required by the fallback generator" >&2
        exit 1
    }
    python3 "$SCRIPT_DIR/generate_fallback.py"
    echo "Generated NewMotion.xcodeproj with the checked-in fallback (XcodeGen not installed)"
fi

