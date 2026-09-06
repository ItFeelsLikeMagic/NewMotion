#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/build/dist"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/release-mac.sh [--dry-run] [--skip-notarize] [--notes <file>]

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

install.sh installs from the newest release's NewMotion.dmg, so publishing is
what puts a build in front of people. It refuses to publish unless the commit
is main, matches origin, and has nothing uncommitted beside it.

  --dry-run        build and verify the files, publish nothing.
  --skip-notarize  passed through to package-mac.sh; implies --dry-run,
                   because Gatekeeper refuses that build everywhere else.
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
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) PUBLISH=0 ;;
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

if [ "$PUBLISH" = "0" ]; then
    echo
    echo "Nothing published. Files are in $DIST_DIR."
    exit 0
fi

[ -f "$DMG" ] || { echo "error: no disk image at $DMG" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "error: no zip at $ZIP" >&2; exit 1; }

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "NewMotion $VERSION"
git push -q origin "$TAG"

echo "==> Publishing the release"
if [ -n "$NOTES" ]; then
    gh release create "$TAG" "$DMG" "$ZIP" \
        --title "NewMotion $VERSION for Mac" --notes-file "$NOTES"
else
    gh release create "$TAG" "$DMG" "$ZIP" \
        --title "NewMotion $VERSION for Mac" --generate-notes
fi

echo
echo "Published $TAG. install.sh now serves this build."
