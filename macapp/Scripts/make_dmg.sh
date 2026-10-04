#!/bin/zsh
# Builds dist/Transcriber-<version>.dmg from the notarized app, then
# signs, notarizes and staples the DMG itself — recipients see "verified" on
# the mount as well as the app.
#
# Run Scripts/build_app.sh and Scripts/notarize.sh first: the app inside must
# already be stapled, so the staple travels inside the DMG.
#
# Env overrides: SKIP_SIGN=1 (leave DMG unsigned), SKIP_NOTARIZE=1,
#                FORCE_DMG=1 (build even if the app isn't stapled)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Transcriber"
PROFILE="${NOTARY_PROFILE:-LESSON_NOTARY}"
APP="dist/$APP_NAME.app"
# Stage OUTSIDE the repo: dist/ lives in iCloud-synced Documents, where Finder
# re-stamps FinderInfo onto the bundle every few minutes — and macOS 13+
# Gatekeeper rejects images containing FinderInfo detritus ("damaged" errors).
STAGE="$(mktemp -d)"

[[ -d "$APP" ]] || { echo "error: $APP not found — run Scripts/build_app.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/$APP_NAME-$VERSION.dmg"

if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not stapled (not notarized) — run Scripts/notarize.sh first," >&2
  echo "       or set FORCE_DMG=1 to build anyway (recipients get Gatekeeper warnings)." >&2
  [[ "${FORCE_DMG:-0}" == "1" ]] || exit 1
fi

echo "==> staging app + /Applications link"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Belt and braces: strip any xattr the sync layer stamped on during the copy.
xattr -cr "$STAGE" 2>/dev/null || true

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"

IDENT=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}' || true)
if [[ -n "$IDENT" && "${SKIP_SIGN:-0}" != "1" ]]; then
  echo "==> signing DMG"
  codesign --force --timestamp --sign "$IDENT" "$DMG"
fi

if [[ "${SKIP_NOTARIZE:-0}" != "1" && -n "${IDENT:-}" ]]; then
  echo "==> notarytool submit DMG (keychain profile: $PROFILE) — waits for Apple"
  if ! OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1); then
    echo "$OUT" >&2
    exit 1
  fi
  echo "$OUT"
  echo "==> stapling DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "==> done: $DMG"
