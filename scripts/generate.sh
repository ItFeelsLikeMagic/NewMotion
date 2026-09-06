#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/generate.sh

Generate NewMotion.xcodeproj from project.yml. Needs XcodeGen. The generated
project is ignored by Git.
HELP
    exit 0
fi

command -v xcodegen >/dev/null 2>&1 || {
    cat >&2 <<'NEEDS_XCODEGEN'
error: XcodeGen is required to generate the project.

    brew install xcodegen
NEEDS_XCODEGEN
    exit 1
}

xcodegen generate --spec "$ROOT_DIR/project.yml"
echo "Generated NewMotion.xcodeproj with XcodeGen"
