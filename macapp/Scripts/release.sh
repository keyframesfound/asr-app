#!/bin/zsh
# Builds, signs and publishes a GitHub release — installed apps pick it up
# through the in-app updater (AppUpdater checks the repo's latest release).
#
# Usage:
#   Scripts/release.sh 1.2.0 "What's new in this release…"
#
# Requires `gh` authenticated once (gh auth login). The repo must be public —
# the updater queries api.github.com without a token.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "usage: $0 VERSION [RELEASE NOTES]" >&2
  echo "       $0 1.2.0 \"Fixes OGG import and speeds up summary generation.\"" >&2
  exit 1
fi
VERSION="$1"
shift
NOTES="${*:-Bug fixes and improvements.}"
TAG="v$VERSION"

REPO="${GITHUB_REPO:-$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')}"
[[ -n "$REPO" ]] || REPO="keyframesfound/asr-app"

echo "==> building app (VERSION=$VERSION)"
VERSION="$VERSION" BUILD="$(date +%Y%m%d)" ./Scripts/build_app.sh

echo "==> notarizing + stapling"
./Scripts/notarize.sh

APP="dist/Lesson Transcriber.app"
ZIP="dist/Lesson Transcriber-$VERSION.zip"
# Re-zip AFTER stapling: the updater payload must carry the notarization
# ticket, or recipients' Gatekeeper rejects the swapped-in app.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> building DMG"
./Scripts/make_dmg.sh
DMG="dist/Lesson Transcriber-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "error: $DMG missing — make_dmg.sh did not produce it." >&2; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found — publish by hand:" >&2
  echo "  1. open https://github.com/$REPO/releases/new?tag=$TAG" >&2
  echo "  2. title \"Lesson Transcriber $VERSION\", notes: $NOTES" >&2
  echo "  3. attach $ZIP and $DMG and publish" >&2
  exit 1
fi

echo "==> creating GitHub release $TAG on $REPO"
gh release create "$TAG" "$ZIP" "$DMG" \
  --repo "$REPO" \
  --title "Lesson Transcriber $VERSION" \
  --notes "$NOTES"

echo "==> published https://github.com/$REPO/releases/tag/$TAG"
echo "    Installed apps offer the update at next launch (or via Check for Updates)."
