#!/bin/bash
# Builds a notarized release and leaves it in build/dist/LiteTranslation-<version>.zip.
#
#   NOTARY_PROFILE=<profile> ./release.sh
#
# <profile> is a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile>
# The version is CFBundleShortVersionString in Support/Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"

# Work outside the project folder. Under ~/Desktop and similar, Finder keeps re-adding
# extended attributes to the bundle, and signature verification and notarization reject them.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Lite Translation.app"

RELEASE=1 ./build.sh "$WORK"
codesign --verify --strict "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
    echo "Notarization needs a Developer ID Application signature." >&2
    exit 1
fi

ditto -c -k --keepParent "$APP" "$WORK/submission.zip"
xcrun notarytool submit "$WORK/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Zipped again, so that the download carries the stapled ticket.
ARCHIVE="build/dist/LiteTranslation-$VERSION.zip"
mkdir -p build/dist
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
