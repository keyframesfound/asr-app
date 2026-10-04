---
name: release-macapp
description: >
  Build, notarize and publish a Transcriber (macapp) release to GitHub
  Releases — DMG for humans + zip for the in-app updater — via the REST API.
  Use whenever the user asks to release, ship, publish or cut a new version of
  the Mac app, make/pack a DMG, or bump the app version — even if they just say
  "release this", "pack it and ship 1.2.0", or "make a new DMG". Do NOT use for
  dev builds (SKIP_SIGN=1) or the PHP web app.
---

# Releasing Transcriber (macapp)

Full pipeline: working tree → built+signed app → notarized+stapled → updater
zip + DMG → published GitHub release. Wall clock ≈ 15–25 min, most of it
waiting on Apple's notary service for the ~450 MB payloads.

Do NOT reach for `macapp/Scripts/release.sh` — it shells out to `gh release
create`, and `gh` is not authenticated on this machine (and its in-place
bundle-signing step loses the iCloud race for model-bundled builds). The
manual steps below are the path that has actually shipped (v1.0.0, v1.1.0).

## Preflight (all read-only, run first)

From `macapp/`:

1. **Signing identity:** `security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2}'` → expect `2D261A564FDA2A8D755E4C059621ED78A8F4B689`.
2. **Notary profile:** `xcrun notarytool history --keychain-profile LESSON_NOTARY --output-format json` must return real JSON (this authenticates against Apple). If it prints `Error: No Keychain password item found for profile`, the profile is GONE — this has happened TWICE (2026-10-01, 2026-10-04) and both times the profile **came back on its own** within ~an hour: it lives in the iCloud-synced (Local Items) keychain, which evicts and re-syncs the item and which the `security` CLI can never see. Response: retry `notarytool history` a few times over the next hour before bothering the user; if `submit` fails mid-session with this error, wait and retry rather than rebuilding anything. The durable fix (user hasn't wanted it) is re-creating the profile WITHOUT `--sync` via `xcrun notarytool store-credentials LESSON_NOTARY --apple-id developer@ssc.edu.hk --team-id Q4398L9H45` (prompts for an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords; a forgotten one is unrecoverable — create a new one). Never pipe the history output into a JSON parse that treats garbage as an empty list — grep for the literal word `Error` first.
3. **Models staged:** `Resources/FluidAudio/Models/` contains `sensevoice-small-coreml` + `silero-vad-coreml` (~452 MB). If missing, run `Scripts/fetch_model.sh` first — releasing without it ships an app that downloads on first run.
4. **Baked config:** repo-root `.env` exists (build bakes OPENROUTER_*/GOOGLE_*/GITHUB_REPO into `config.plist`).
5. **GitHub credential:** the PAT comes from the keychain, and it MUST be queried with the path or you get a different, broken credential (see gotcha 4). Capture it into a variable and do not print it — it's a live secret:
   ```sh
   PAT=$(printf "protocol=https\nhost=github.com\npath=keyframesfound/asr-app.git\n" \
     | git credential fill | awk -F= '/^password=/{print $2}')
   ```
   Sanity-check WITHOUT echoing it: `curl -s -H "Authorization: Bearer $PAT" https://api.github.com/user | python3 -c 'import json,sys;print(json.load(sys.stdin).get("login"))'` → `keyframesfound`. A `None`/401 means you queried without `path=`.

## Decide the version and what goes in

- **First command of the session: `export VERSION=X.Y.Z`** — every later step (build, zip, DMG, publish) references `$VERSION`, and `build_app.sh` silently defaults to 1.0.0 when it's unset, which would bake the wrong version and overwrite the previous release's artifacts.
- Version comes from the user (e.g. "release 1.2.0"). Semver, no `v` prefix in scripts; tags get the `v`.
- Surface uncommitted changes and ask what to include if the user didn't say ("pack everything" = commit the working tree as-is). Mechanical typos in user-edited strings may be fixed, but disclose the fix. Untracked non-app directories (e.g. `.agents/` — this skill itself) are NOT app code: leave them out of the release commit unless the user asks.
- Draft release notes to `/tmp/lt-notes-$VERSION.md` (the publish step reads exactly that path). Plain-English bullet list of what changed, modeled on the v1.1.0 release body (`curl -s https://api.github.com/repos/keyframesfound/asr-app/releases/tags/v1.1.0 | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"])'`). Source: `git log v<previous>..HEAD --oneline` plus user input; if the tag is already at HEAD, the notes are just whatever this release is for (the user's ask + any commit you're about to make). Mention a download-size change when the payload grows/shrinks — teachers notice; final size is only known after the build, so refresh the draft body before publishing (step 3 of Publish).
- Commit + push `main`, then `git tag vX.Y.Z` on that commit and push the tag.

## Build and sign

1. `cd macapp && BUILD="$(date +%Y%m%d)" ./Scripts/build_app.sh`   # VERSION comes from the session export
   - Sets up DEVELOPER_DIR for full Xcode itself; bundles models + icon + baked config; signs inside-out with the Developer ID identity.
   - **Gate before trusting the build:** `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "dist/Transcriber.app/Contents/Info.plist"` must print `$VERSION`. If it prints 1.0.0, VERSION wasn't set — rebuild, do not continue.
   - **If the final bundle codesign fails with "resource fork, Finder information, or similar detritus not allowed" — that's expected with the 452 MB model bundle.** The compile/bundle/config steps succeeded; do NOT retry signing in `dist/` (iCloud re-stamps xattrs faster than you can strip them). Move to staging.
2. Stage and sign OUTSIDE the repo (this is where the real signature happens):
   ```sh
   WORK=$(mktemp -d /tmp/lt-release-XXXX)
   # Name the bundle correctly NOW — the updater zip inherits this directory name.
   ditto "dist/Transcriber.app" "$WORK/Transcriber.app"
   APP="$WORK/Transcriber.app"
   xattr -cr "$APP"
   CS=(codesign --force --options runtime --timestamp --sign 2D261A564FDA2A8D755E4C059621ED78A8F4B689)  # hash from preflight step 1
   "${CS[@]}" "$APP/Contents/MacOS/ltctl"
   "${CS[@]}" "$APP/Contents/MacOS/LessonTranscriber"
   "${CS[@]}" "$APP"
   codesign --verify --strict "$APP"
   ```
   (Missing ltctl? `build_app.sh` copies it when present; skip that line.)

## Notarize and staple the app

```sh
cd "$WORK"
ditto -c -k --keepParent "Transcriber.app" .notarize.zip
xcrun notarytool submit .notarize.zip --keychain-profile LESSON_NOTARY --wait   # 5–10 min
xcrun stapler staple "Transcriber.app"
xcrun stapler validate "Transcriber.app"   # must print "The validate action worked!"
```

- **Do not run `spctl -a` at all during a release** — not before stapling (it caches the per-cdhash "rejected / Unnotarized Developer ID" verdict, which then persists even after stapling, on fresh paths too; only `sudo pkill -9 syspolicyd` clears it — sudo needs a password here) and not after stapling as a "final check" (same poisoned verdict comes back and wastes an investigation loop). The gates that count: `stapler validate` printing "The validate action worked!" + `notarytool history --keychain-profile LESSON_NOTARY --output-format json` showing the submission **Accepted**. Recipients are unaffected either way.

## Updater zip + DMG

```sh
cd "<repo>/macapp"
ditto -c -k --keepParent "$WORK/Transcriber.app" "dist/Transcriber-$VERSION.zip"
# Payload sanity: version + baked repo + models present, .app at zip root
unzip -l "dist/Transcriber-$VERSION.zip" | head -5     # must show "Transcriber.app/" first
unzip -p "dist/Transcriber-$VERSION.zip" "Transcriber.app/Contents/Info.plist" | plutil -p - | grep ShortVersion   # must equal $VERSION
rm -rf "dist/Transcriber.app"
ditto "$WORK/Transcriber.app" "dist/Transcriber.app"   # stapled copy for make_dmg.sh
./Scripts/make_dmg.sh    # validates staple, stages outside the repo itself, signs + notarizes + staples the DMG
```

`make_dmg.sh` reads the version from the app's Info.plist → `dist/Lesson
Transcriber-$VERSION.dmg`. The zip's top-level directory MUST be `Lesson
Transcriber.app/` — the updater unpacks and swaps in whatever is at the root,
so a generically-named staging dir (`app/`) produces an update that can't
install.

**App renamed in v1.3.0** ("Lesson Transcriber" → "Transcriber"): the bundle
name, zip/DMG asset names and updater zip root are `Transcriber*` from here
on. The bundle ID (`com.asrweb.lesson-transcriber`), the keychain service, the
`Application Support/LessonTranscriber` data dir and the `LessonTranscriber`
executable name are DELIBERATELY unchanged (lessons, settings and the Google
sign-in survive; the unpack guard compares bundle IDs). `AppUpdater` installs
the update under the staged bundle's own name and removes the old-named
bundle, so v1.2.0 users end up with `/Applications/Transcriber.app`.

## Publish: draft → upload → publish

`$VERSION` must still be set in this shell (the session export from earlier). Body and asset paths all depend on it.

```sh
PAT=$(printf "protocol=https\nhost=github.com\npath=keyframesfound/asr-app.git\n" \
  | git credential fill | awk -F= '/^password=/{print $2}')

# 1. Draft release (invisible to the updater and to humans)
curl -s -X POST -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github+json" \
  -d "$(python3 -c 'import json;print(json.dumps({"tag_name":"vX.Y.Z","target_commitish":"main","name":"Transcriber X.Y.Z","body":open("/tmp/notes.md").read(),"draft":True,"prerelease":False}))')" \
  https://api.github.com/repos/keyframesfound/asr-app/releases        # → note "id"

# 2. Upload BOTH assets (~450 MB each, minutes; --retry for flaky wifi)
curl -s --retry 3 -X POST -H "Authorization: Bearer $PAT" -H "Content-Type: application/zip" \
  --data-binary @"dist/Transcriber-$VERSION.zip" \
  "https://uploads.github.com/repos/keyframesfound/asr-app/releases/<id>/assets?name=Transcriber-$VERSION.zip"
curl -s --retry 3 -X POST -H "Authorization: Bearer $PAT" -H "Content-Type: application/x-apple-diskimage" \
  --data-binary @"dist/Transcriber-$VERSION.dmg" \
  "https://uploads.github.com/repos/keyframesfound/asr-app/releases/<id>/assets?name=Transcriber-$VERSION.dmg"
#   GitHub stores the names dot-separated (Transcriber-1.3.0.zip) — expected.

# 3. Refresh the notes with final payload sizes (see "Decide the version"), then publish
#    only after both assets report "uploaded"
curl -s -X PATCH -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github+json" \
  -d "$(python3 -c 'import json;d={"draft":False};print(json.dumps(d))')" \
  https://api.github.com/repos/keyframesfound/asr-app/releases/<id>
#    (to also update the body in the same call: d={"draft":False,"body":open("/tmp/lt-notes-$VERSION.md").read()})
```

Draft-then-publish matters: the updater reads `releases/latest`, so publishing
early with only the zip attached would point every installed app at a
zip-only release before the DMG lands.

Verify exactly what users see (anonymous = how the updater queries):
```sh
curl -s https://api.github.com/repos/keyframesfound/asr-app/releases/latest | python3 -c "
import json,sys; r=json.load(sys.stdin)
print(r['tag_name'], r['published_at'])
[print(' ', a['name'], round(a['size']/1e6), 'MB', a['state']) for a in r['assets']]"
```

## Failure playbook

- **notarytool submit fails:** it prints a submission id → `xcrun notarytool log <id> --keychain-profile LESSON_NOTARY` names the offending file. Historically: FinderInfo xattr detritus (strip in staging), or an un-signed nested binary.
- **Credential 401 at any API step:** re-run `git credential fill` WITH `path=keyframesfound/asr-app.git`.
- **Local `spctl` says "Unnotarized Developer ID" but `stapler validate` passes:** poisoned local cache (see above) — not a real failure; ship.
- **Publishing crashed mid-upload:** assets can be re-POSTed to the same draft id (re-upload overwrites by name).

## After the release

- Leave `dist/` holding the stapled app, zip, and DMG for the version — that's the canonical local artifact set.
- Clean up: remove `$WORK`, the PAT from any temp file, and scratch JSON.
- Remind the user once per release: public assets carry baked OPENROUTER_API_KEY + GOOGLE_CLIENT_SECRET (their deliberate choice — spend cap at openrouter.ai/keys is the mitigation).
