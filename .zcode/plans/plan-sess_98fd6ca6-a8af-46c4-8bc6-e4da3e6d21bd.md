# Goal

Package `Lesson Transcriber.app` (macapp/) as a Developer ID–signed, notarized, stapled **DMG** that opens on any Apple Silicon Mac (macOS 14+) with zero Gatekeeper warnings.

## Current state (verified during exploration)

- `macapp/Scripts/build_app.sh` builds with `swift build -c release`, hand-assembles the `.app`, then signs **ad-hoc** (`codesign --force --deep --sign -`). No Developer ID identity, no hardened runtime, no timestamp, no notarization, no DMG step — this is exactly why it shows as "locked/damaged" on other Macs.
- No entitlements are needed: no App Sandbox, no JIT (SenseVoice runs on the ANE via Core ML), statically linked. The hardened runtime works with an empty entitlement set.
- The build bakes live OpenRouter + Google OAuth secrets into `Contents/Resources/config.plist` — staying baked per your choice; the README will document the risk.
- The binary is arm64-only, macOS 14+. Intel Macs can't run it regardless of signing; the DMG/README will state Apple Silicon required.

## Step 1 — Developer ID Application certificate (needs ~10 min of your interaction)

I first check the keychain (`security find-identity -v -p codesigning`), then walk you through:

1. Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority → save the CSR to disk.
2. developer.apple.com → Certificates, IDs & Profiles → Certificates → **+** → Developer ID Application → upload the CSR → download the `.cer` → double-click to install.
3. Verify the identity appears and record your **Team ID** from the Membership page.
4. One-time notarization credential (interactive; prompts for a password): create an app-specific password at appleid.apple.com, then run:
   `xcrun notarytool store-credentials LESSON_NOTARY --apple-id <your Apple ID> --team-id <TEAMID>`
   After this one command, every later step runs non-interactively.

I'll write the Step 2–4 scripts while you do this, and can dry-run the build with `SKIP_SIGN=1` meanwhile.

## Step 2 — Proper signing in `macapp/Scripts/build_app.sh`

Replace the ad-hoc `--deep` signing with inside-out signing (no `--deep` — it's deprecated and doesn't propagate the hardened runtime):

1. `codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY"` on the nested helper binary (`Contents/MacOS/ltctl`)
2. Same on the main executable (`Contents/MacOS/LessonTranscriber`)
3. Same on the `.app` bundle root (seals the resources)

`SIGN_IDENTITY` defaults to auto-detecting the first `Developer ID Application` identity in the keychain; `SKIP_SIGN=1` keeps ad-hoc signing for local dev builds. Version/build become env-overridable with the current `1.0.0`/`1` defaults.

## Step 3 — Notarize + staple (new `macapp/Scripts/notarize.sh`)

- Zip with `ditto -c -k --keepParent` → `xcrun notarytool submit --keychain-profile LESSON_NOTARY --wait` → `xcrun stapler staple` → verify with `spctl -a -vvv -t exec` (expect "accepted … Notarized Developer ID") and `stapler validate`.
- If Apple rejects it, pull `xcrun notarytool log <submission-id>` and fix the specific reported issue before re-submitting.

## Step 4 — DMG (new `macapp/Scripts/make_dmg.sh`)

- Staging folder containing the stapled app plus an `/Applications` symlink (standard drag-to-install layout).
- `hdiutil create -format UDZO` → `dist/Lesson Transcriber-<version>.dmg`.
- Then sign, notarize, and staple the DMG itself as well, so even the mount shows the "verified" badge.

## Step 5 — Docs

Add a "Distributing the app" section to the README: system requirements (Apple Silicon, macOS 14+), first launch downloads the ~450 MB SenseVoice model (one-time, needs network), optional `brew install ffmpeg` for OGG input, how recipients can verify (`spctl -a -vv`), and the baked-secrets warning: **anyone holding the DMG can extract the OpenRouter key and Google client secret** — share only with people you trust, set a spending cap on the OpenRouter key, and rotate the keys if the DMG ever leaks.

## Step 6 — End-to-end verification

Run the full pipeline: build → sign → notarize → staple → DMG. Then a Gatekeeper simulation: mount the DMG, copy the app out, apply a quarantine xattr, and confirm `spctl -a` accepts it. Report the final DMG path and size.

**Sequencing note:** Step 1 blocks the real signing run until you've created the certificate and stored the notary credential — that's the only part I can't do for you. Everything else is built first and verified as far as ad-hoc allows.