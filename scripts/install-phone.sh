#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DERIVED_DATA="${NEWMOTION_DERIVED_DATA:-$ROOT_DIR/DerivedData}"
UDID="${IPHONE_UDID:-}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: IPHONE_UDID=<device-identifier> ./scripts/install-phone.sh [--udid ID]

Build the iPhone app for a physical device and install it with devicectl.
The identifier may be supplied via --udid or IPHONE_UDID. Signing/team setup,
Trust This Computer, and Developer Mode remain deliberate GUI prerequisites.

By default signing is disabled for a safe build-only probe. For a real device,
set NEWMOTION_SIGNING=1 and NEWMOTION_DEVELOPMENT_TEAM locally (optionally
NEWMOTION_CODE_SIGN_IDENTITY; defaults to "Apple Development"). Signed mode
selects the supplied device as the build destination and allows Xcode to update
or register the local development profile. These values are read only from the
environment and are never written to the repository.
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

"$SCRIPT_DIR/generate.sh"
if [ "${NEWMOTION_SIGNING:-0}" = "1" ]; then
    SIGNING_TEAM="${NEWMOTION_DEVELOPMENT_TEAM:-}"
    [ -n "$SIGNING_TEAM" ] || {
        echo "error: NEWMOTION_DEVELOPMENT_TEAM is required when NEWMOTION_SIGNING=1" >&2
        exit 2
    }
    SIGNING_IDENTITY="${NEWMOTION_CODE_SIGN_IDENTITY:-Apple Development}"
    xcodebuild -project "$ROOT_DIR/NewMotion.xcodeproj" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme NewMotion-iOS -sdk iphoneos -destination "platform=iOS,id=$UDID" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
        CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$SIGNING_TEAM" CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES ENABLE_DEBUG_DYLIB=NO
else
    # Debug dylibs are extra unsigned binaries. iOS kills the app on open if they
    # are not signed, so device builds keep a single signed executable.
    xcodebuild -project "$ROOT_DIR/NewMotion.xcodeproj" -configuration Debug -derivedDataPath "$DERIVED_DATA" -scheme NewMotion-iOS -sdk iphoneos build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_DEBUG_DYLIB=NO
fi
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/NewMotion.app"
[ -d "$APP_PATH" ] || { echo "error: expected app not found at $APP_PATH" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
xcrun devicectl device install app --device "$UDID" "$APP_PATH"

# The bundle prefix is an environment value, so a run with a different one
# leaves a second app behind that looks identical on the home screen. Only
# builds of this app are matched, and only the one just installed survives.
xcrun devicectl device info apps --device "$UDID" |
    awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.newmotion\.ios$/) print $i }' |
    while read -r stale; do
        if [ "$stale" != "$BUNDLE_ID" ]; then
            echo "Removing older install: $stale"
            xcrun devicectl device uninstall app --device "$UDID" "$stale"
        fi
    done
