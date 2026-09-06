#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

PROJECT="$ROOT_DIR/NewMotion.xcodeproj"
DERIVED_DATA="${NEWMOTION_DERIVED_DATA:-$ROOT_DIR/DerivedData}"
DIST_DIR="$ROOT_DIR/build/dist"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/package-mac.sh [--skip-notarize]

Build the Mac companion for distribution: Release, signed with Developer ID,
hardened runtime on, secure timestamp, notarized by Apple, and stapled so it
opens on a Mac that has never seen it and has no network.

Output lands in build/dist:
  NewMotion.app      stapled, ready to run
  NewMotion.zip      the same app zipped, ready to upload somewhere

Environment:
  NEWMOTION_DEVELOPMENT_TEAM  required. Your ten-character team id.
  NEWMOTION_NOTARY_PROFILE    required unless --skip-notarize. The name of
                                 a notarytool keychain profile. Create it once:

    xcrun notarytool store-credentials <profile-name> \
        --apple-id <your Apple ID> \
        --team-id <your team id> \
        --password <an app-specific password from appleid.apple.com>

  NEWMOTION_CODE_SIGN_IDENTITY  optional. Defaults to the Developer ID
                                   Application identity in your keychain.

--skip-notarize signs and packages but does not send anything to Apple. The
result runs on this Mac and is refused by Gatekeeper on any other, so use it
only to check the signing half.

This does not touch ~/Applications. Use install-mac.sh for the local dev copy;
that one signs for development, which is a different certificate.
HELP
    exit 0
fi

NOTARIZE=1
if [ "${1:-}" = "--skip-notarize" ]; then
    NOTARIZE=0
    shift
fi
[ "$#" -eq 0 ] || { echo "error: unknown argument: $1" >&2; exit 2; }

command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

TEAM="${NEWMOTION_DEVELOPMENT_TEAM:-}"
[ -n "$TEAM" ] || {
    echo "error: NEWMOTION_DEVELOPMENT_TEAM is required" >&2
    exit 2
}

# A Developer ID Application certificate is not the same as the Apple
# Development one the local install uses, and only the paid Developer Program
# can issue it. Say so plainly rather than failing inside codesign.
IDENTITY="${NEWMOTION_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)
fi
[ -n "$IDENTITY" ] || {
    cat >&2 <<'MISSING'
error: no "Developer ID Application" certificate in your keychain.

That certificate is what lets a Mac other than this one open the app, and it
is separate from the "Apple Development" one already here. To get it:

  1. Join the Apple Developer Program (99 USD a year) if you have not.
  2. In Xcode: Settings, Accounts, your team, Manage Certificates,
     the + button, "Developer ID Application".
  3. Run this script again.

To check the rest of the pipeline before then: ./scripts/package-mac.sh --skip-notarize
MISSING
    exit 1
}

PROFILE="${NEWMOTION_NOTARY_PROFILE:-}"
if [ "$NOTARIZE" = "1" ] && [ -z "$PROFILE" ]; then
    echo "error: NEWMOTION_NOTARY_PROFILE is required; see --help, or pass --skip-notarize" >&2
    exit 2
fi

# Copied back into the repository only at the very end. The zip is the thing
# to distribute: it carries the signature intact, whatever the synced folder
# stamps on the loose copy afterwards.
deliver() {
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    ditto "$STAGE_APP" "$DIST_DIR/NewMotion.app"
    ditto "$ZIP" "$DIST_DIR/NewMotion.zip"
}

"$SCRIPT_DIR/generate.sh"

echo "==> Building Release"
# Built unsigned and signed afterwards, the same way install-mac.sh does it:
# xcodebuild's own CodeSign step trips over Finder metadata in this tree.
xcodebuild -project "$PROJECT" -configuration Release -derivedDataPath "$DERIVED_DATA" \
    -scheme NewMotion-macOS -sdk macosx build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ENABLE_DEBUG_DYLIB=NO >/dev/null

BUILT="$DERIVED_DATA/Build/Products/Release/NewMotion.app"
[ -d "$BUILT" ] || { echo "error: expected app not found at $BUILT" >&2; exit 1; }

# Signing happens outside the repository. This tree sits under a synced
# folder, and its file provider stamps com.apple.FinderInfo back onto every
# file the moment it is cleared, which codesign refuses to verify past.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
STAGE_APP="$WORK/NewMotion.app"
ditto --norsrc --noextattr --noacl "$BUILT" "$STAGE_APP"
xattr -cr "$STAGE_APP"

echo "==> Signing as $IDENTITY"
# Inside out: a nested bundle signed after its container invalidates the
# container's seal. --timestamp and --options runtime are both notarization
# requirements, not preferences.
FRAMEWORK="$STAGE_APP/Contents/Frameworks/NewMotionShared.framework/Versions/A"
if [ -d "$FRAMEWORK" ]; then
    codesign --force --sign "$IDENTITY" --team-identifier "$TEAM" \
        --options runtime --timestamp "$FRAMEWORK"
fi
codesign --force --sign "$IDENTITY" --team-identifier "$TEAM" \
    --options runtime --timestamp "$STAGE_APP"

codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
codesign --display --verbose=2 "$STAGE_APP" 2>&1 | grep -q "flags=.*runtime" || {
    echo "error: the signature does not carry the hardened runtime flag" >&2
    exit 1
}

ZIP="$WORK/NewMotion.zip"
if [ "$NOTARIZE" = "0" ]; then
    ditto -c -k --keepParent "$STAGE_APP" "$ZIP"
    deliver
    echo
    echo "Signed but NOT notarized. It runs here and Gatekeeper refuses it"
    echo "anywhere else. Do not ship this."
    exit 0
fi

echo "==> Notarizing (this takes a few minutes)"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
# The ticket goes onto the app, so it opens on a Mac that is offline and has
# never asked Apple about it. The shippable zip has to be made after this.
xcrun stapler staple "$STAGE_APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP"

echo "==> Verifying as Gatekeeper sees it"
xcrun stapler validate "$STAGE_APP"
spctl --assess --type exec --verbose=4 "$STAGE_APP"

deliver
echo
echo "Ready to ship:"
echo "  $DIST_DIR/NewMotion.app"
echo "  $DIST_DIR/NewMotion.zip"
