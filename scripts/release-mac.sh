#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/build/dist"
DERIVED_DATA="${NEWMOTION_DERIVED_DATA:-$ROOT_DIR/DerivedData}"
REPO=ItFeelsLikeMagic/NewMotion

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/release-mac.sh [--dry-run] [--skip-notarize] [--critical]
                               [--notes <file>]

Cut a Mac release from the commit you are on. It packages with
package-mac.sh, tags the commit, and publishes the GitHub release with the
disk image and the zip attached.

The version is whatever MARKETING_VERSION says in project.yml; the tag is that
with a v in front. Bump it and merge that first: this script never edits it,
and it stops if the tag already exists.

Before you run it:

  1. Merge everything you want in the release into main.
  2. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml, and
     merge that too.
  3. Pull main, then run ./scripts/test.sh.
  4. Run this.

install.sh installs from the newest release's NewMotion.dmg, and copies
already out there read appcast.xml from the newest release and update
themselves to it. Publishing is what puts a build in front of people, new
and old alike. It refuses to publish unless the commit is main, matches
origin, and has nothing uncommitted beside it.

  --dry-run        build and verify the files, publish nothing.
  --skip-notarize  passed through to package-mac.sh; implies --dry-run,
                   because Gatekeeper refuses that build everywhere else.
  --critical       mark this release critical. Installed copies stop holding
                   it for a quiet moment and ask the user to install it now.
                   For a security fix or a build that breaks without it;
                   ordinary releases should not use this, because the whole
                   point of the rest of the design is that nobody is
                   interrupted.
  --notes <file>   release notes to publish. Without it, GitHub writes them
                   from the commits, which is thinner than what the install
                   instructions on the last release said.

Environment: the same NEWMOTION_ variables package-mac.sh needs. See
./scripts/package-mac.sh --help.
HELP
    exit 0
fi

PUBLISH=1
PACKAGE_ARGS=""
NOTES=""
CRITICAL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) PUBLISH=0 ;;
        --critical) CRITICAL=1 ;;
        --skip-notarize) PACKAGE_ARGS="--skip-notarize"; PUBLISH=0 ;;
        --notes)
            shift
            NOTES="${1:-}"
            [ -n "$NOTES" ] || { echo "error: --notes needs a file" >&2; exit 2; }
            [ -f "$NOTES" ] || { echo "error: no such notes file: $NOTES" >&2; exit 2; }
            ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"*\([^"[:space:]]*\)"*[[:space:]]*$/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || { echo "error: no MARKETING_VERSION in project.yml" >&2; exit 1; }
TAG="v$VERSION"

git diff --quiet && git diff --cached --quiet || {
    echo "error: commit what is in your tree first; a release has to name a commit" >&2
    exit 1
}

if [ "$PUBLISH" = "1" ]; then
    command -v gh >/dev/null 2>&1 || {
        echo "error: the GitHub CLI is required to publish; install gh, or pass --dry-run" >&2
        exit 1
    }
    gh auth status >/dev/null 2>&1 || {
        echo "error: gh is not logged in; run gh auth login" >&2
        exit 1
    }
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
        || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
        echo "error: $TAG already exists; bump MARKETING_VERSION in project.yml" >&2
        exit 1
    fi
    git fetch -q origin main
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        echo "error: releases are cut from main; this commit is not origin/main" >&2
        exit 1
    fi
fi

echo "==> Releasing $TAG"
# shellcheck disable=SC2086
"$SCRIPT_DIR/package-mac.sh" $PACKAGE_ARGS

DMG="$DIST_DIR/NewMotion.dmg"
ZIP="$DIST_DIR/NewMotion.zip"
APPCAST="$DIST_DIR/appcast.xml"

[ -f "$DMG" ] || { echo "error: no disk image at $DMG" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "error: no zip at $ZIP" >&2; exit 1; }

# The feed installed copies read. Sparkle compares CURRENT_PROJECT_VERSION,
# which generate_appcast takes from the app inside the zip, so the number in
# project.yml has to have gone up or nobody is offered this build.
echo "==> Writing the update feed"
GENERATE_APPCAST=$(find "$DERIVED_DATA/SourcePackages/artifacts" \
    -name generate_appcast -type f -perm -u+x 2>/dev/null | head -1)
[ -n "$GENERATE_APPCAST" ] || {
    echo "error: generate_appcast not found under $DERIVED_DATA." >&2
    echo "It ships with the Sparkle package; build once so SwiftPM fetches it." >&2
    exit 1
}

# Fed a directory of its own holding only the zip. Pointed at the whole dist
# folder it would also read the disk image and write a second entry for the
# same version, and Sparkle updates from the zip.
FEED_ROOM="$DIST_DIR/.feed"
rm -rf "$FEED_ROOM"
mkdir -p "$FEED_ROOM"
ditto "$ZIP" "$FEED_ROOM/NewMotion.zip"
# An empty --critical-update-version means critical no matter which version
# the copy out there is coming from.
if [ "$CRITICAL" = "1" ]; then
    echo "    marking $TAG critical"
    "$GENERATE_APPCAST" \
        --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
        --critical-update-version "" \
        -o "$APPCAST" "$FEED_ROOM"
else
    "$GENERATE_APPCAST" \
        --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
        -o "$APPCAST" "$FEED_ROOM"
fi
rm -rf "$FEED_ROOM"
[ -s "$APPCAST" ] || { echo "error: the feed came out empty" >&2; exit 1; }

if [ "$PUBLISH" = "0" ]; then
    echo
    echo "Nothing published. Files are in $DIST_DIR."
    exit 0
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "NewMotion $VERSION"
git push -q origin "$TAG"

echo "==> Publishing the release"
if [ -n "$NOTES" ]; then
    gh release create "$TAG" "$DMG" "$ZIP" "$APPCAST" \
        --title "NewMotion $VERSION for Mac" --notes-file "$NOTES"
else
    gh release create "$TAG" "$DMG" "$ZIP" "$APPCAST" \
        --title "NewMotion $VERSION for Mac" --generate-notes
fi

echo
echo "Published $TAG. install.sh serves this build, and copies already"
echo "installed will update themselves to it within a day."
