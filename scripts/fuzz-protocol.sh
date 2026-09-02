#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT="$ROOT_DIR/PhoneRemote.xcodeproj"
DERIVED_DATA="${PHONE_REMOTE_DERIVED_DATA:-$ROOT_DIR/DerivedData}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/fuzz-protocol.sh [--help]

Run the deterministic 2,000-input bounded decoder corpus from
ProtocolTests.testDecoderBoundedDeterministicFuzzCorpus. The test uses a fixed
seed and logs no input bytes. Override PHONE_REMOTE_DERIVED_DATA as needed.
HELP
    exit 0
fi

"$SCRIPT_DIR/generate.sh"
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

xcodebuild test \
    -project "$PROJECT" \
    -scheme PhoneRemoteSharedTests \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:PhoneRemoteSharedTests/ProtocolTests/testDecoderBoundedDeterministicFuzzCorpus \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
