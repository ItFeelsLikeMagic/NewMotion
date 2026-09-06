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
  NewMotion.dmg      the only thing to hand out

A disk image, and deliberately nothing else. A zipped Mac app loses its
Apple seal on the way through chat apps, file sync, and third-party
unarchivers, and the Mac at the far end then refuses to open it. A disk
image is one opaque file that macOS mounts itself, so nothing in the middle
can touch the app inside. A zip is still made on the way, because that is
the shape Apple's notary service takes an app in, but it is not delivered:
offering both downloads only lets someone pick the fragile one.

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

# Copied back into the repository only at the very end, and only as archives.
# A loose .app here would be re-stamped with Finder metadata by the synced
# folder and is exactly the copy someone would drag into a chat window.
deliver() {
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    if [ -f "$DMG" ]; then
        ditto "$DMG" "$DIST_DIR/NewMotion.dmg"
    else
        ditto "$ZIP" "$DIST_DIR/NewMotion.zip"
    fi
}

# The app goes in beside a link to /Applications, which is the drag-to-install
# window every Mac user already knows.
build_dmg() {
    ROOM="$WORK/dmg"
    rm -rf "$ROOM"
    mkdir -p "$ROOM"
    ditto --norsrc --noextattr --noacl "$STAGE_APP" "$ROOM/NewMotion.app"
    xcrun stapler staple "$ROOM/NewMotion.app" >/dev/null
    ln -s /Applications "$ROOM/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname NewMotion -srcfolder "$ROOM" \
        -fs HFS+ -format UDZO -ov "$DMG"
    codesign --force --sign "$IDENTITY" --team-identifier "$TEAM" \
        --timestamp "$DMG"
}

"$SCRIPT_DIR/generate.sh"

echo "==> Building Release"
# Built unsigned and signed afterwards, the same way install-mac.sh does it:
# xcodebuild's own CodeSign step trips over Finder metadata in this tree.
xcodebuild -project "$PROJECT" -configuration Release -derivedDataPath "$DERIVED_DATA" \
    -scheme NewMotion-macOS -destination "generic/platform=macOS" build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ENABLE_DEBUG_DYLIB=NO ONLY_ACTIVE_ARCH=NO >/dev/null

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
DMG="$WORK/NewMotion.dmg"
if [ "$NOTARIZE" = "0" ]; then
    ditto -c -k --keepParent "$STAGE_APP" "$ZIP"
    deliver
    echo
    echo "Signed but NOT notarized. It runs here and Gatekeeper refuses it"
    echo "anywhere else. Do not ship this."
    exit 0
fi

echo "==> Notarizing the app (this takes a few minutes)"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the app"
# The ticket goes onto the app, so it opens on a Mac that is offline and has
# never asked Apple about it. Both archives have to be made after this.
xcrun stapler staple "$STAGE_APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP"

# A disk image is notarized in its own right. Stapling the ticket to the image
# as well as to the app means the download opens even offline, before anything
# has been dragged out of it.
echo "==> Building and notarizing the disk image"
build_dmg
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying as Gatekeeper sees it"
xcrun stapler validate "$STAGE_APP"
xcrun stapler validate "$DMG"
spctl --assess --type exec --verbose=4 "$STAGE_APP"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

deliver
echo
echo "Ready to ship:"
echo "  $DIST_DIR/NewMotion.dmg"
