#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT="$ROOT_DIR/NewMotion.xcodeproj"
DERIVED_DATA="${NEWMOTION_DERIVED_DATA:-$ROOT_DIR/DerivedData}"
INSTALL_DIR="${NEWMOTION_MAC_INSTALL_DIR:-/Applications}"
INSTALL_APP="$INSTALL_DIR/NewMotion.app"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/install-mac.sh

Build the Mac companion and replace /Applications/NewMotion.app, then
launch only that copy. Do not open DerivedData or /tmp builds; macOS ties
Accessibility to the exact app path and signature.

By default signing is off. For Accessibility and Keychain to survive rebuilds,
set NEWMOTION_SIGNING=1 and NEWMOTION_DEVELOPMENT_TEAM locally
(optionally NEWMOTION_CODE_SIGN_IDENTITY; defaults to "Apple Development").
Those values are never written to the repository.

/Applications is where install.sh puts the release copy, so the dev copy
lands on the same path and inherits the same Accessibility grant.

Override NEWMOTION_MAC_INSTALL_DIR only if you must use a different stable
folder. Keep it an Applications folder, not a throwaway build directory.
HELP
    exit 0
fi

[ "$#" -eq 0 ] || { echo "error: unknown argument: $1" >&2; exit 2; }
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

"$SCRIPT_DIR/generate.sh"

# Sign after copy. xcodebuild CodeSign fails on Finder metadata in this tree.
xcodebuild -project "$PROJECT" -configuration Debug -derivedDataPath "$DERIVED_DATA" \
    -scheme NewMotion-macOS -sdk macosx build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ENABLE_DEBUG_DYLIB=NO

APP_PATH="$DERIVED_DATA/Build/Products/Debug/NewMotion.app"
[ -d "$APP_PATH" ] || { echo "error: expected app not found at $APP_PATH" >&2; exit 1; }

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
[ -w "$INSTALL_DIR" ] || {
    echo "error: cannot write to $INSTALL_DIR. Re-run with NEWMOTION_MAC_INSTALL_DIR=\"\$HOME/Applications\"." >&2
    exit 1
}
if pgrep -x NewMotion >/dev/null 2>&1; then
    pkill -x NewMotion || true
    i=0
    while pgrep -x NewMotion >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        sleep 0.1
        i=$((i + 1))
    done
fi

rm -rf "$INSTALL_APP"
ditto "$APP_PATH" "$INSTALL_APP"
xattr -cr "$INSTALL_APP"

if [ "${NEWMOTION_SIGNING:-0}" = "1" ]; then
    SIGNING_TEAM="${NEWMOTION_DEVELOPMENT_TEAM:-}"
    [ -n "$SIGNING_TEAM" ] || {
        echo "error: NEWMOTION_DEVELOPMENT_TEAM is required when NEWMOTION_SIGNING=1" >&2
        exit 2
    }
    SIGNING_IDENTITY="${NEWMOTION_CODE_SIGN_IDENTITY:-Apple Development}"

    # Nested code is sealed by whatever encloses it, so it signs inside out.
    # Sparkle carries its own helper app and XPC services; re-signing only the
    # outer app leaves their signatures sealed under the old one and the
    # --deep verify below rejects the result.
    sign() {
        # An early return, not a guard: under set -e a false test here would
        # end the install silently, with the app already replaced.
        [ -e "$1" ] || return 0
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$1"
    }

    SPARKLE="$INSTALL_APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign "$SPARKLE/XPCServices/Downloader.xpc"
    sign "$SPARKLE/XPCServices/Installer.xpc"
    sign "$SPARKLE/Autoupdate"
    sign "$SPARKLE/Updater.app"
    sign "$SPARKLE"
    sign "$INSTALL_APP/Contents/Frameworks/NewMotionShared.framework/Versions/A"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$INSTALL_APP"
    codesign --verify --deep --strict "$INSTALL_APP"
else
    echo "warning: unsigned install; Accessibility may need a fresh toggle after each rebuild" >&2
fi

open "$INSTALL_APP"

echo "Installed and launched: $INSTALL_APP"
echo "Grant Accessibility to this copy only, then Refresh Accessibility in the app."
