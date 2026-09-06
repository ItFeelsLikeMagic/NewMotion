#!/bin/sh
# Install NewMotion for Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/ItFeelsLikeMagic/NewMotion/main/install.sh | sh
#
# Downloads the latest release, checks Apple signed and notarized it and that
# it came from us, then puts it in Applications and starts it.
set -eu

REPO=ItFeelsLikeMagic/NewMotion
TEAM_ID=4B8P47VZGT
DMG_URL="https://github.com/$REPO/releases/latest/download/NewMotion.dmg"
INSTALL_DIR="${NEWMOTION_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/NewMotion.app"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "NewMotion is a Mac app; this is not a Mac."

# The app is built against macOS 15 and will not launch below it. Saying so now
# is kinder than a download followed by a shrug from Finder.
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 15 ] || die "NewMotion needs macOS 15 or later; this is $(sw_vers -productVersion)."

WORK=$(mktemp -d)
cleanup() {
    [ -n "${MOUNT:-}" ] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

printf 'Downloading NewMotion...\n'
curl -fsSL --retry 3 -o "$WORK/NewMotion.dmg" "$DMG_URL" \
    || die "could not download $DMG_URL"

# Checked before anything is mounted or copied. A script fetched over the
# network and piped into a shell has no business trusting what it just pulled
# down, and these are the same checks the Mac would make on a double-click.
printf 'Checking Apple signed it...\n'
spctl --assess --type open --context context:primary-signature "$WORK/NewMotion.dmg" >/dev/null 2>&1 \
    || die "the downloaded disk image is not notarized by Apple. Refusing to install it."

MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/NewMotion.dmg" \
    || die "could not open the disk image"

SOURCE="$MOUNT/NewMotion.app"
[ -d "$SOURCE" ] || die "the disk image does not contain NewMotion.app"

codesign --verify --deep --strict "$SOURCE" 2>/dev/null \
    || die "the app's signature does not check out. Refusing to install it."
spctl --assess --type exec "$SOURCE" >/dev/null 2>&1 \
    || die "the app is not notarized by Apple. Refusing to install it."

# Notarization proves Apple saw it; this proves it is ours and not somebody
# else's notarized app served from a hijacked link.
SIGNER=$(codesign -dv --verbose=4 "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$SIGNER" = "$TEAM_ID" ] \
    || die "signed by team '$SIGNER', expected '$TEAM_ID'. Refusing to install it."

if pgrep -x NewMotion >/dev/null 2>&1; then
    printf 'Quitting the copy already running...\n'
    osascript -e 'quit app "NewMotion"' >/dev/null 2>&1 || pkill -x NewMotion || true
    i=0
    while pgrep -x NewMotion >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        sleep 0.25
        i=$((i + 1))
    done
fi

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
[ -w "$INSTALL_DIR" ] || die "cannot write to $INSTALL_DIR. Re-run with NEWMOTION_INSTALL_DIR=\"\$HOME/Applications\"."

printf 'Installing to %s...\n' "$APP"
rm -rf "$APP"
# ditto rather than cp: it keeps the symlinks inside the framework intact, and
# a broken symlink in there is a broken signature.
ditto "$SOURCE" "$APP" || die "could not copy the app into $INSTALL_DIR"

hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
MOUNT=

codesign --verify --deep --strict "$APP" 2>/dev/null \
    || die "the installed copy does not verify. Something went wrong copying it."

open "$APP" || true

cat <<DONE

NewMotion is installed at $APP and running. It updates itself from now on.

It lives in the menu bar, not the Dock. Look for the cursor icon up there.

One thing left, and it cannot be done for you: open System Settings, go to
Privacy and Security, then Accessibility, and switch NewMotion on. That is
what lets it move your cursor and type for you. Nothing works without it.

Then click the menu bar icon to pair your iPhone.
DONE
