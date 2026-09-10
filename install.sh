#!/bin/sh
# Install NewMotion for Mac.
#
#   curl -fsSL https://itfeelslikemagic.github.io/NewMotion/install.sh | sh
#
# Downloads the latest release, checks that Apple notarized it and that we
# signed it, then puts it in Applications and starts it.
set -eu

REPO=ItFeelsLikeMagic/NewMotion
TEAM_ID=4B8P47VZGT
SCRIPT_URL="https://itfeelslikemagic.github.io/NewMotion/install.sh"
DMG_URL="https://github.com/$REPO/releases/latest/download/NewMotion.dmg"
RELEASES_URL="https://github.com/$REPO/releases"
ISSUES_URL="https://github.com/$REPO/issues"
INSTALL_DIR="${NEWMOTION_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/NewMotion.app"

RETRY="Run this command again. If it still fails, download NewMotion.dmg by hand from
  $RELEASES_URL"
REPORT="Run this command again. If it fails the same way, report it at
  $ISSUES_URL"

# First argument is the error, the rest are remedy lines.
die() {
    printf 'error: %s\n' "$1" >&2
    shift
    [ $# -eq 0 ] || printf '%s\n' "$@" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "NewMotion is a Mac app and this is not a Mac."

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 15 ] \
    || die "NewMotion needs macOS 15 or later and this Mac has $(sw_vers -productVersion)." \
        "Update macOS in System Settings > General > Software Update, then run this command again."

WORK=$(mktemp -d)
STAGE="$INSTALL_DIR/.NewMotion.app.new"
OLD="$INSTALL_DIR/.NewMotion.app.old"
cleanup() {
    [ -n "${MOUNT:-}" ] && hdiutil detach -quiet "$MOUNT" 2>/dev/null
    # An interrupt between the two renames below would otherwise leave no app.
    if [ ! -d "$APP" ] && [ -d "$OLD" ]; then mv "$OLD" "$APP" || true; fi
    rm -rf "$WORK" "$STAGE"
}
trap cleanup EXIT INT TERM

# The bar only when a person is watching; in a log it is noise.
if [ -t 2 ]; then PROGRESS=--progress-bar; else PROGRESS=-s; fi

printf 'Downloading NewMotion...\n'
curl -fSL $PROGRESS --retry 3 --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
    -o "$WORK/NewMotion.dmg" "$DMG_URL" \
    || die "could not download $DMG_URL" "$RETRY"

# Same checks Gatekeeper makes on a double-click, before anything is mounted.
printf 'Verifying signature and notarization...\n'
spctl --assess --type open --context context:primary-signature "$WORK/NewMotion.dmg" >/dev/null 2>&1 \
    || die "the downloaded disk image is not notarized by Apple, so it was not installed." \
        "$REPORT"

MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/NewMotion.dmg" \
    || die "could not open the downloaded disk image." "$RETRY"

SOURCE="$MOUNT/NewMotion.app"
[ -d "$SOURCE" ] || die "the disk image does not contain NewMotion.app." "$REPORT"

codesign --verify --deep --strict "$SOURCE" 2>/dev/null \
    || die "the app's signature does not verify, so it was not installed." "$REPORT"
spctl --assess --type exec "$SOURCE" >/dev/null 2>&1 \
    || die "the app is not notarized by Apple, so it was not installed." "$REPORT"

# Notarization proves Apple saw it; the team ID proves it is ours.
SIGNER=$(codesign -dv --verbose=4 "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$SIGNER" = "$TEAM_ID" ] \
    || die "the app is signed by team '$SIGNER', not '$TEAM_ID', so it was not installed." "$REPORT"

if pgrep -x NewMotion >/dev/null 2>&1; then
    printf 'Quitting the running copy...\n'
    osascript -e 'quit app "NewMotion"' >/dev/null 2>&1 || pkill -x NewMotion || true
    i=0
    while pgrep -x NewMotion >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        sleep 0.25
        i=$((i + 1))
    done
    pgrep -x NewMotion >/dev/null 2>&1 \
        && die "NewMotion is still running, so it was not replaced." \
            "Quit it from its menu bar icon, then run this command again."
fi

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
[ -w "$INSTALL_DIR" ] || die "cannot write to $INSTALL_DIR." \
    "Run it again with a folder you own:" \
    "  curl -fsSL $SCRIPT_URL | NEWMOTION_INSTALL_DIR=\"\$HOME/Applications\" sh"

printf 'Installing to %s...\n' "$APP"
# Copy beside the old app and verify before swapping, so a failure here leaves
# the existing copy untouched. ditto rather than cp: cp breaks the framework
# symlinks, and a broken symlink is a broken signature.
rm -rf "$STAGE"
ditto "$SOURCE" "$STAGE" \
    || die "could not copy the app into $INSTALL_DIR. Nothing was changed." "$RETRY"

hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
MOUNT=

codesign --verify --deep --strict "$STAGE" 2>/dev/null \
    || die "the copy in $INSTALL_DIR does not verify. Nothing was changed." "$REPORT"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$STAGE/Contents/Info.plist") \
    || die "could not read the version of the copied app. Nothing was changed." "$REPORT"

# A rename keeps the final path exact, which the Accessibility grant is bound to.
rm -rf "$OLD"
if [ -d "$APP" ]; then
    mv "$APP" "$OLD" \
        || die "could not move the old copy aside. Nothing was changed." "$RETRY"
fi
mv "$STAGE" "$APP" || {
    [ ! -d "$OLD" ] || mv "$OLD" "$APP"
    die "could not move the app into place. The previous copy was put back." "$RETRY"
}
rm -rf "$OLD"

if open "$APP" 2>/dev/null; then
    printf '\nNewMotion %s is installed at %s and running.\n' "$VERSION" "$APP"
else
    printf '\nNewMotion %s is installed at %s but did not launch.\nOpen it yourself:\n  open "%s"\n' \
        "$VERSION" "$APP" "$APP"
fi

cat <<DONE
It lives in the menu bar, not the Dock, and updates itself from now on.

Next steps:
  1. Click Allow when it asks to use Bluetooth. That is how it reaches your iPhone.
  2. Open System Settings > Privacy & Security > Accessibility and turn on NewMotion.
     It cannot move the cursor or type without this.
  3. Click the menu bar icon to pair your iPhone.

Stuck? $ISSUES_URL
DONE
