#!/bin/zsh
# Builds the release binaries and bundles "Lesson Transcriber.app" into dist/.
#
# Requires either full Xcode (SwiftUI macro plugins) or Command Line Tools.
# Xcode is preferred; DEVELOPER_DIR is set per-invocation so the system
# xcode-select setting is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Lesson Transcriber"
BUNDLE_ID="com.asrweb.lesson-transcriber"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"

# Prefer full Xcode when present (SwiftUI's @State etc. need its macro plugin).
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "==> swift build (release)"
swift build -c release
xattr -rc .build 2>/dev/null || true

BIN="$(swift build -c release --show-bin-path)"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/LessonTranscriber" "$APP/Contents/MacOS/"
cp "$BIN/ltctl" "$APP/Contents/MacOS/ltctl" 2>/dev/null || true

# Icon: generate an iconset and convert to .icns (needs Xcode's iconutil,
# present in CLT too).
if command -v iconutil >/dev/null; then
  echo "==> icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift Scripts/make_icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>           <string>LessonTranscriber</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
  <key>CFBundleVersion</key>              <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>       <string>14.0</string>
  <key>LSApplicationCategoryType</key>    <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
</dict>
</plist>
PLIST

# Bake service credentials into the bundle (config.plist) so teachers never
# configure anything. Values come from the repo .env. SKIP_CONFIG=1 skips this
# (dev builds fall back to reading the repo .env directly).
if [[ "${SKIP_CONFIG:-0}" != "1" && -f "../.env" ]]; then
  echo "==> config (baked from .env)"
  get_env() {
    grep -E "^$1=" ../.env | head -1 | cut -d= -f2- | tr -d '"' \
      | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
  }
  OR_KEY=$(get_env OPENROUTER_API_KEY)
  OR_MODEL=$(get_env OPENROUTER_MODEL)
  G_ID=$(get_env GOOGLE_CLIENT_ID)
  G_SECRET=$(get_env GOOGLE_CLIENT_SECRET)
  # Repo whose Releases feed the in-app updater: .env value, else the git
  # remote, else the fallback constant in AppUpdater.
  GH_REPO=$(get_env GITHUB_REPO || true)
  [[ -n "$GH_REPO" ]] || GH_REPO="${GITHUB_REPO:-$(git -C .. config --get remote.origin.url 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##' || true)}"
  [[ -n "$GH_REPO" ]] || GH_REPO="keyframesfound/asr-web"
  [[ -n "$OR_MODEL" ]] || OR_MODEL="deepseek/deepseek-chat"
  cat > "$APP/Contents/Resources/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>OPENROUTER_API_KEY</key>  <string>$OR_KEY</string>
  <key>OPENROUTER_MODEL</key>    <string>$OR_MODEL</string>
  <key>GOOGLE_CLIENT_ID</key>    <string>$G_ID</string>
  <key>GOOGLE_CLIENT_SECRET</key><string>$G_SECRET</string>
  <key>GITHUB_REPO</key>         <string>$GH_REPO</string>
</dict>
</plist>
PLIST
fi

# Gatekeeper (macOS 13+) rejects bundles whose files carry FinderInfo or
# resource forks — Finder stamps the bundle when dist/ is browsed. Xattrs are
# not part of the code signature, so stripping them never invalidates it.
xattr -cr "$APP" 2>/dev/null || true

# Distribution builds are signed with a "Developer ID Application" identity,
# inside-out (nested helper first, then main executable, then bundle) with the
# hardened runtime and a secure timestamp — both are required for notarization.
# --deep is deprecated and does not propagate the hardened-runtime flag.
# SKIP_SIGN=1 keeps the old ad-hoc signature for local dev builds.
if [[ "${SKIP_SIGN:-0}" == "1" ]]; then
  echo "==> codesign (ad-hoc, SKIP_SIGN=1)"
  codesign --force --deep --sign - "$APP"
else
  IDENT="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}' || true)}"
  if [[ -z "$IDENT" ]]; then
    echo "error: no 'Developer ID Application' identity in the keychain." >&2
    echo "       Create one (see README 'Distributing the app') or build with SKIP_SIGN=1." >&2
    exit 1
  fi
  echo "==> codesign (Developer ID, hardened runtime): $IDENT"
  CS=(codesign --force --options runtime --timestamp --sign "$IDENT")
  if [[ -f "$APP/Contents/MacOS/ltctl" ]]; then
    "${CS[@]}" "$APP/Contents/MacOS/ltctl"
  fi
  "${CS[@]}" "$APP/Contents/MacOS/LessonTranscriber"
  "${CS[@]}" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

# The zip is the auto-update asset: it must contain the .app at the top level
# (that's what AppUpdater unpacks and swaps in), so --keepParent, not -r.
echo "==> zip (GitHub release asset)"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "    $ZIP"

echo "==> done: $APP"
