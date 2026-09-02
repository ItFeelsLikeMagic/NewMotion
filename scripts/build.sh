#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT="$ROOT_DIR/PhoneRemote.xcodeproj"
DERIVED_DATA="${PHONE_REMOTE_DERIVED_DATA:-$ROOT_DIR/DerivedData}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/build.sh [--help]

Generate and build both app targets plus all unit-test bundles. The default
build uses generic iOS and macOS destinations with signing disabled. Override
PHONE_REMOTE_DERIVED_DATA to choose a local DerivedData directory.
HELP
    exit 0
fi

"$SCRIPT_DIR/generate.sh"
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

echo "Building iOS app"
xcodebuild -project "$PROJECT" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme PhoneRemote-iOS -sdk iphoneos build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Building macOS app"
xcodebuild -project "$PROJECT" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme PhoneRemote-macOS -sdk macosx build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Building shared/macOS unit-test bundle"
xcodebuild -project "$PROJECT" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme PhoneRemoteSharedTests -sdk macosx build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Building iOS unit-test bundle"
xcodebuild -project "$PROJECT" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme PhoneRemote-iOSTests -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Building macOS unit-test bundle"
xcodebuild -project "$PROJECT" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme PhoneRemote-macOSTests -sdk macosx build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
echo "Build complete: $DERIVED_DATA"
