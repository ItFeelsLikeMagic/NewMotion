#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT="$ROOT_DIR/NewMotion.xcodeproj"
DERIVED_DATA="${NEWMOTION_DERIVED_DATA:-$ROOT_DIR/DerivedData}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/test.sh [--help]

Generate and run the shared protocol/transport/observability tests plus the
macOS app smoke tests. The iOS test bundle is compiled by build.sh; execution
requires an installed iOS simulator and can be requested with
NEWMOTION_RUN_IOS_TESTS=1. Set NEWMOTION_IOS_DESTINATION to override the
automatically selected available iPhone simulator.

The macOS test host runs inert: no Bluetooth, no login Keychain, no speech
server, so a run never raises a system approval dialog. The tests that use the
real Keychain need someone to approve the prompts and run only with
NEWMOTION_KEYCHAIN_TESTS=1.
HELP
    exit 0
fi

"$SCRIPT_DIR/generate.sh"
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

echo "Running shared protocol/transport/observability tests on macOS"
xcodebuild test -project "$PROJECT" -scheme NewMotionSharedTests -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Running macOS app smoke tests"
if [ "${NEWMOTION_KEYCHAIN_TESTS:-0}" = "1" ]; then
    echo "Keychain tests enabled; macOS will ask you to approve Keychain access"
    export TEST_RUNNER_NEWMOTION_KEYCHAIN_TESTS=1
fi
xcodebuild test -project "$PROJECT" -scheme NewMotion-macOSTests -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

if [ "${NEWMOTION_RUN_IOS_TESTS:-0}" = "1" ]; then
    echo "Running iOS smoke tests"
    IOS_DESTINATION="${NEWMOTION_IOS_DESTINATION:-}"
    if [ -z "$IOS_DESTINATION" ]; then
        IOS_DEVICE_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone [^(]+ \([0-9A-Fa-f-]{36}\)/ { print $2; exit }')
        if [ -z "$IOS_DEVICE_ID" ]; then
            echo "error: no available iPhone simulator; set NEWMOTION_IOS_DESTINATION or install an iOS simulator runtime" >&2
            exit 1
        fi
        IOS_DESTINATION="platform=iOS Simulator,id=$IOS_DEVICE_ID"
    fi
    echo "Using iOS destination: $IOS_DESTINATION"
    xcodebuild test -project "$PROJECT" -scheme NewMotion-iOSTests -destination "$IOS_DESTINATION" -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
else
    echo "Skipping iOS execution (set NEWMOTION_RUN_IOS_TESTS=1 when a simulator is available)"
fi
