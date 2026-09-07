#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

PROJECT="$ROOT_DIR/NewMotion.xcodeproj"
DIST_DIR="$ROOT_DIR/build/dist"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/testflight-phone.sh [--build N] [--dry-run]

Archive the iPhone app for the App Store and upload it to TestFlight. The
build shows up in App Store Connect a few minutes later; internal testers can
install it once Apple finishes processing it.

The version is whatever MARKETING_VERSION says in project.yml. The build
number is CURRENT_PROJECT_VERSION, and App Store Connect refuses a build
number it has already accepted for that version, so --build N raises it for a
single run without editing the repository.

Environment:
  NEWMOTION_DEVELOPMENT_TEAM  required. Your ten-character team id.
  NEWMOTION_ASC_KEY_ID        required unless --dry-run.
  NEWMOTION_ASC_ISSUER_ID     required unless --dry-run.
  NEWMOTION_ASC_KEY_PATH      required unless --dry-run. The AuthKey_*.p8
                                file. Make the key in App Store Connect under
                                Users and Access, Integrations, App Store
                                Connect API, with the App Manager role. Apple
                                lets you download it once. Keep it outside
                                this repository.

  --build N   use N as the build number for this upload only.
  --dry-run   archive and write build/dist/NewMotion.ipa, upload nothing.
              Needs the certificate but no API key, so it checks the whole
              signing half on its own.

Signing is automatic: the first run may create the Apple Distribution
certificate and the App Store profile for you. The app record has to exist in
App Store Connect first, under the bundle id com.davidliao.newmotion.ios.
HELP
    exit 0
fi

UPLOAD=1
BUILD=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) UPLOAD=0 ;;
        --build)
            shift
            BUILD="${1:-}"
            [ -n "$BUILD" ] || { echo "error: --build needs a number" >&2; exit 2; }
            ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild is required; install the full Xcode toolchain" >&2
    exit 1
}

TEAM="${NEWMOTION_DEVELOPMENT_TEAM:-}"
[ -n "$TEAM" ] || { echo "error: NEWMOTION_DEVELOPMENT_TEAM is required" >&2; exit 2; }

VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"*\([^"[:space:]]*\)"*[[:space:]]*$/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || { echo "error: no MARKETING_VERSION in project.yml" >&2; exit 1; }
if [ -z "$BUILD" ]; then
    BUILD=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"*\([^"[:space:]]*\)"*[[:space:]]*$/\1/p' project.yml | head -1)
    [ -n "$BUILD" ] || { echo "error: no CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1; }
fi

# An App Store Connect API key rather than an Apple ID: it uploads without a
# password prompt or a two-factor code, and xcodebuild takes the file by path,
# which altool does not. The same key also lets automatic signing create the
# distribution certificate on a Mac that has never had one.
if [ "$UPLOAD" = "1" ]; then
    for var in NEWMOTION_ASC_KEY_ID NEWMOTION_ASC_ISSUER_ID NEWMOTION_ASC_KEY_PATH; do
        eval "value=\${$var:-}"
        [ -n "$value" ] || {
            echo "error: $var is required to upload; see --help, or pass --dry-run" >&2
            exit 2
        }
    done
    [ -f "$NEWMOTION_ASC_KEY_PATH" ] || {
        echo "error: no key file at $NEWMOTION_ASC_KEY_PATH" >&2
        exit 2
    }
    set -- -authenticationKeyPath "$NEWMOTION_ASC_KEY_PATH" \
        -authenticationKeyID "$NEWMOTION_ASC_KEY_ID" \
        -authenticationKeyIssuerID "$NEWMOTION_ASC_ISSUER_ID"
    DESTINATION=upload
else
    set --
    DESTINATION=export
fi

"$SCRIPT_DIR/generate.sh"

# The archive and its build products stay out of the repository. This tree
# sits under a synced folder whose file provider stamps com.apple.FinderInfo
# back onto every file, and codesign refuses to seal past it, so a signed
# build inside DerivedData here fails partway through.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
ARCHIVE="$WORK/NewMotion.xcarchive"

echo "==> Archiving $VERSION ($BUILD)"
xcodebuild -project "$PROJECT" -scheme NewMotion-iOS -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$WORK/DerivedData" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates "$@" \
    archive \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
    CURRENT_PROJECT_VERSION="$BUILD" >/dev/null

[ -d "$ARCHIVE/Products/Applications/NewMotion.app" ] || {
    echo "error: the archive holds no app; check the build output above" >&2
    exit 1
}

# manageAppVersionAndBuildNumber off, or Xcode picks the build number itself
# and --build stops meaning anything.
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

if [ "$UPLOAD" = "1" ]; then
    echo "==> Uploading to App Store Connect"
else
    echo "==> Exporting the ipa"
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" \
    -exportPath "$WORK/export" \
    -allowProvisioningUpdates "$@"

if [ "$UPLOAD" = "0" ]; then
    mkdir -p "$DIST_DIR"
    ditto "$WORK/export/NewMotion.ipa" "$DIST_DIR/NewMotion.ipa"
    echo
    echo "Signed but NOT uploaded: $DIST_DIR/NewMotion.ipa"
    exit 0
fi

echo
echo "Uploaded $VERSION ($BUILD)."
echo "Apple processes it for a few minutes, then it appears under TestFlight"
echo "in App Store Connect. Internal testers can install it right away."
