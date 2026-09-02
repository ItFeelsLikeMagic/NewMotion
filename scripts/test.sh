#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT="$ROOT_DIR/PhoneRemote.xcodeproj"
DERIVED_DATA="${PHONE_REMOTE_DERIVED_DATA:-$ROOT_DIR/DerivedData}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/test.sh [--help]

Generate and run the shared protocol/transport/observability tests plus the
macOS app smoke tests. The iOS test bundle is compiled by build.sh; execution
requires an installed iOS simulator and can be requested with
PHONE_REMOTE_RUN_IOS_TESTS=1. Set PHONE_REMOTE_IOS_DESTINATION to override the
automatically selected available iPhone simulator.
HELP
    exit 0
fi

"$SCRIPT_DIR/generate.sh"
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

echo "Running shared protocol/transport/observability tests on macOS"
xcodebuild test -project "$PROJECT" -scheme PhoneRemoteSharedTests -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Running macOS app smoke tests"
xcodebuild test -project "$PROJECT" -scheme PhoneRemote-macOSTests -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

if [ "${PHONE_REMOTE_RUN_IOS_TESTS:-0}" = "1" ]; then
    echo "Running iOS smoke tests"
    IOS_DESTINATION="${PHONE_REMOTE_IOS_DESTINATION:-}"
    if [ -z "$IOS_DESTINATION" ]; then
        IOS_DEVICE_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone [^(]+ \([0-9A-Fa-f-]{36}\)/ { print $2; exit }')
        if [ -z "$IOS_DEVICE_ID" ]; then
            echo "error: no available iPhone simulator; set PHONE_REMOTE_IOS_DESTINATION or install an iOS simulator runtime" >&2
            exit 1
        fi
        IOS_DESTINATION="platform=iOS Simulator,id=$IOS_DEVICE_ID"
    fi
    echo "Using iOS destination: $IOS_DESTINATION"
    xcodebuild test -project "$PROJECT" -scheme PhoneRemote-iOSTests -destination "$IOS_DESTINATION" -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
else
    echo "Skipping iOS execution (set PHONE_REMOTE_RUN_IOS_TESTS=1 when a simulator is available)"
fi
