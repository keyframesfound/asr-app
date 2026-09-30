#!/bin/zsh
# Notarizes dist/Lesson Transcriber.app with Apple and staples the ticket.
#
# Requires the app to be Developer ID signed (Scripts/build_app.sh without
# SKIP_SIGN=1) and a one-time keychain profile:
#   xcrun notarytool store-credentials LESSON_NOTARY \
#     --apple-id <your Apple ID> --team-id <TEAMID>
#
# Env overrides: NOTARY_PROFILE (keychain profile name, default LESSON_NOTARY)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Lesson Transcriber"
PROFILE="${NOTARY_PROFILE:-LESSON_NOTARY}"
APP="dist/$APP_NAME.app"
ZIP="dist/.notarize.zip"

[[ -d "$APP" ]] || { echo "error: $APP not found — run Scripts/build_app.sh first" >&2; exit 1; }

echo "==> checking signature"
# (No pipes with grep -q here: under pipefail, grep's early exit SIGPIPEs
# codesign and flips the result. Match on captured output instead.)
SIG_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$SIG_INFO" != *"Developer ID"* ]]; then
  echo "error: $APP is not Developer ID signed — rebuild without SKIP_SIGN=1" >&2
  exit 1
fi

echo "==> zipping"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarytool submit (keychain profile: $PROFILE) — waits for Apple, ~2-10 min"
if ! OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1); then
  echo "$OUT" >&2
  ID=$(awk '/id:/ {print $2; exit}' <<<"$OUT" || true)
  if [[ -n "$ID" ]]; then
    echo "==> rejected — fetching the log for $ID:" >&2
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  exit 1
fi
echo "$OUT"

echo "==> stapling"
xcrun stapler staple "$APP"

echo "==> verifying Gatekeeper assessment"
spctl -a -vvv -t exec "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
echo "==> notarized + stapled: $APP"
