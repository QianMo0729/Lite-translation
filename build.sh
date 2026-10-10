#!/bin/bash
# Builds and signs "Lite Translation.app".
#
#   ./build.sh [output directory]        default: build
#
# Signs with the first Developer ID Application certificate in the keychain, or ad-hoc when
# there is none. SIGN_IDENTITY overrides the choice ("-" forces ad-hoc).
#
# macOS ties the Accessibility and Screen Recording grants to the signature. A certificate
# keeps them across rebuilds; an ad-hoc signature changes with every build and loses them.
set -euo pipefail
cd "$(dirname "$0")"

OUTPUT="${1:-build}"
APP="$OUTPUT/Lite Translation.app"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --product LiteTranslation
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/LiteTranslation" "$APP/Contents/MacOS/LiteTranslation"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Finder tags bundles in folders such as ~/Desktop with extended attributes, which codesign rejects.
xattr -cr "$APP"

# A trusted timestamp comes from Apple's server. Notarization requires one; everyday builds
# skip it so that building doesn't depend on the network.
TIMESTAMP="--timestamp=none"
if [ "${RELEASE:-}" = 1 ]; then TIMESTAMP="--timestamp"; fi
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP (signed with: $SIGN_IDENTITY)"
