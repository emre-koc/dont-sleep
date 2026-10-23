#!/bin/bash
# ./build.sh           Local build for this Mac (ad-hoc signed).
# ./build.sh release   Universal build, Developer ID signed with hardened runtime,
#                      notarized and stapled, packaged as dist/*.zip and dist/*.dmg.
#
# Release settings (environment variables):
#   SIGN_ID         codesign identity (default: first "Developer ID Application" in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: DontSleep)
#   SKIP_NOTARIZE=1 sign and package only
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-dev}
APP=DontSleep.app
BUILD=.build
DIST=dist
MIN_MACOS=13.0
mkdir -p "$BUILD"

# App icon: regenerate when the eye artwork or the generator changes.
ICON="$BUILD/AppIcon.icns"
if [[ ! -f "$ICON" || Sources/EyeIcon.swift -nt "$ICON" || Tools/AppIcon/main.swift -nt "$ICON" ]]; then
  swiftc -swift-version 5 Tools/AppIcon/main.swift Sources/EyeIcon.swift -o "$BUILD/make-icon" -framework AppKit
  rm -rf "$BUILD/AppIcon.iconset"
  "$BUILD/make-icon" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ICON"
fi

compile() { # compile <arch> <output>
  swiftc -O -swift-version 5 -target "$1-apple-macos$MIN_MACOS" \
    Sources/*.swift -o "$2" \
    -framework AppKit -framework IOKit -framework ServiceManagement
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

if [[ "$MODE" != release ]]; then
  compile "$(uname -m)" "$APP/Contents/MacOS/DontSleep"
  codesign --force --sign - "$APP"
  echo "Built $APP"
  exit 0
fi

# ---- Release ----

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
NOTARY_PROFILE=${NOTARY_PROFILE:-DontSleep}
[[ -n "$SIGN_ID" ]] || { echo "No 'Developer ID Application' identity in the keychain." >&2; exit 1; }

if [[ "${SKIP_NOTARIZE:-}" != 1 ]] &&
   ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
No notarization credentials saved under the profile "$NOTARY_PROFILE". Save them once with:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id TEAM_ID
(or run with SKIP_NOTARIZE=1 to sign without notarizing)
EOF
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
NAME="DontSleep-$VERSION"

echo "==> Building universal binary"
compile arm64 "$BUILD/DontSleep-arm64"
compile x86_64 "$BUILD/DontSleep-x86_64"
lipo -create "$BUILD/DontSleep-arm64" "$BUILD/DontSleep-x86_64" -output "$APP/Contents/MacOS/DontSleep"

echo "==> Signing with: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

notarize() { # notarize <file>
  echo "==> Notarizing $(basename "$1") (this usually takes a few minutes)"
  local result="$BUILD/notary.json"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result" || true
  local status id
  status=$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)
  if [[ "$status" != Accepted ]]; then
    id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
    echo "Notarization failed (status: $status)." >&2
    cat "$result" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

rm -rf "$DIST"
mkdir -p "$DIST"

# The app is notarized and stapled first, so both the zip and the dmg carry a stapled app.
if [[ "${SKIP_NOTARIZE:-}" != 1 ]]; then
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  notarize "$BUILD/notarize.zip"
  xcrun stapler staple "$APP"
fi

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"

STAGE="$BUILD/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname DontSleep -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
codesign --force --timestamp --sign "$SIGN_ID" "$DIST/$NAME.dmg"

if [[ "${SKIP_NOTARIZE:-}" != 1 ]]; then
  notarize "$DIST/$NAME.dmg"
  xcrun stapler staple "$DIST/$NAME.dmg"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DIST/$NAME.dmg"
fi

echo "==> Done: $DIST/$NAME.zip, $DIST/$NAME.dmg"
