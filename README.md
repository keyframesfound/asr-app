# Lesson Transcriber

Lesson recordings in → transcripts, AI summaries and Google Form quizzes out. Two variants share the same SenseVoice model and the same feature set:

| | **Mac app** (`macapp/`) | **Web app** (`public/` + `asr-service/`) |
|---|---|---|
| Runs as | Native SwiftUI app on Apple Silicon | PHP site + Python sidecar |
| Transcription | SenseVoice-Small on the **Apple Neural Engine** (Core ML, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) + Silero VAD | SenseVoice-Small via FunASR (torch/MPS or onnx) + FSMN-VAD |
| Needs | Nothing installed — no ffmpeg, no Python (except OGG decoding, see below) | PHP 8 + Python sidecar + ffmpeg |
| Config | Baked into the app at build time from `.env` | `.env` file |
| Best for | Teachers, one Mac, fully offline transcription | Self-hosted multi-user deployment |

## Mac app

### Daily use

Open **Lesson Transcriber.app** (built into `macapp/dist/`), drop an MP3 (or WAV/M4A/AAC/OGG/FLAC/MP4) onto the window, pick the lesson-audio language (auto / Cantonese / Mandarin / English) and it transcribes **on this Mac** — nothing is uploaded. Then:

- **✨ AI Summary** — Overview / Key Points / Key Terms / Examples / Follow-ups, written in 繁體中文（香港）, 简体中文 or English. The **Settings** pane (sidebar, or ⌘,) chooses the length: **Brief**, **Standard** or **In-depth**.
- **📝 Generate Google Form Quiz** — writes the questions, then creates a quiz-mode Google Form in your Drive (1 point each, correct answers marked, explanations on wrong answers). The first quiz asks for a Google sign-in in your browser; you stay signed in (log out any time in Settings). The quiz card shows the **student link** and an **Edit form** link.
- **⬇ Word** on the transcript/summary cards — formatted `.docx` downloads.
- **Share** — the transcript card button (or right-click a lesson → Share…) opens the macOS share sheet with the transcript (and summary) Word files.
- **Right-click a lesson** in the sidebar to **Rename…**, **Share…** or **Delete** it.

Lessons (audio + transcript + summary + quiz) are saved under `~/Library/Application Support/LessonTranscriber/`. A first transcription downloads the SenseVoice model (~0.5 GB, once); everything after that is fully offline. Rough speed on an M2 Pro: a 1-hour lesson in ~2–4 minutes; the 26-second sample takes under a second.

To bring over transcripts made with the web app:

```bash
cd macapp
.build/release/ltctl import --audio lesson.mp3 --txt ../transcripts/<job>.txt --name "F2 Maths Lesson 3"
```

### Building it

```bash
macapp/Scripts/build_app.sh      # → macapp/dist/Lesson Transcriber.app
```

Requires Xcode (full Xcode, not just Command Line Tools — SwiftUI's macros need its plugins) on an Apple Silicon Mac. The script:

1. `swift build -c release` (the `LessonTranscriber` GUI app + the `ltctl` dev CLI).
2. Generates the app icon (`Scripts/make_icon.swift` → `iconutil`).
3. **Bakes credentials**: copies `OPENROUTER_API_KEY`, `OPENROUTER_MODEL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` from the repo `.env` into `Contents/Resources/config.plist` — teachers never configure anything. `SKIP_CONFIG=1` skips this (dev builds fall back to reading the repo `.env`).
4. Codesigns **Developer ID + hardened runtime** when a Developer ID Application identity is in the keychain (auto-detected) — ad-hoc otherwise, or force it with `SKIP_SIGN=1`.

> Secrets inside the bundle are fine for internal school distribution — do not ship the app publicly.

### Distributing the app (DMG)

`Scripts/build_app.sh` (signed) → `Scripts/notarize.sh` (Apple notarization + staple) → `Scripts/make_dmg.sh` → `dist/Lesson Transcriber-<version>.dmg`. The DMG has a drag-to-Applications layout and is itself signed, notarized and stapled, so it opens on any **Apple Silicon Mac (macOS 14+)** with zero Gatekeeper warnings.

One-time setup (paid Apple Developer Program, ~10 min):

1. **Developer ID Application certificate** — Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority (save the CSR to disk) → upload it at developer.apple.com → Certificates → **+** → *Developer ID Application* → download the `.cer` and open it. Verify: `security find-identity -v -p codesigning` shows `Developer ID Application: <name> (<TEAMID>)`.
2. **Notarization credential** — create an app-specific password at appleid.apple.com, then (once):
   ```bash
   xcrun notarytool store-credentials LESSON_NOTARY --apple-id <your Apple ID> --team-id <TEAMID>
   ```

Then build the DMG:

```bash
macapp/Scripts/build_app.sh    # Developer ID signed, hardened runtime
macapp/Scripts/notarize.sh     # Apple notarization + staple (~2–10 min)
macapp/Scripts/make_dmg.sh     # → macapp/dist/Lesson Transcriber-<version>.dmg (also notarized)
```

`SKIP_SIGN=1` (ad-hoc dev build), `SKIP_NOTARIZE=1` / `FORCE_DMG=1` (skip the Apple submission) for local testing. Recipients: first transcription downloads the SenseVoice model (~0.5 GB, once); OGG input needs `brew install ffmpeg`. They can verify with `spctl -a -vv "/Applications/Lesson Transcriber.app"` → `source=Notarized Developer ID`.

> The baked API keys travel inside the DMG — anyone holding it can extract the OpenRouter key and Google client secret from `Contents/Resources/config.plist`. Share only with people you trust, keep a spending cap on the OpenRouter key, and rotate both if a copy ever leaks.

### Updating installed apps (in-app updater)

The app checks GitHub Releases at launch (and every 12 hours) and shows an update pill in the sidebar plus a **Updates** section in Settings: **Download & Install** fetches the release zip, then **Restart to Update** quits, swaps the app bundle in place and relaunches. There's also **Check for Updates…** in the app menu (⌘, opens Settings → Updates). Automatic checks can be turned off in Settings.

Releasing an update is one command:

```bash
gh auth login                       # once
macapp/Scripts/release.sh 1.1.0 "Faster transcription, fixed OGG import."
```

That builds + codesigns the app, zips it as `dist/Lesson Transcriber-1.1.0.zip` and publishes GitHub release `v1.1.0` with the zip attached — every installed copy offers it within 12 hours. Publishing by hand works too: create the release on GitHub, tag it `v1.1.0`, and attach the zip from `Scripts/build_app.sh VERSION=1.1.0` (the zip must contain the `.app` at the top level, which is how the script builds it).

Rules the updater relies on:

- The repo must be **public** — update checks hit `api.github.com` without a token. The repo slug is baked from `git remote get-url origin` (override with `GITHUB_REPO=owner/repo` or a `GITHUB_REPO=` line in `.env`).
- Tag releases `vX.Y.Z` matching the app version (`VERSION`/`CFBundleShortVersionString`); the updater refuses to install a bundle whose version doesn't match the release tag.
- Mark test builds as **pre-release** on GitHub — "latest release" skips them, so teachers never see them.
- Copies installed before the updater existed (v1.0.0) update once manually; from this version on, updates are in-app.

### Google sign-in (one-time setup)

Create an OAuth client (type **Desktop app**) at console.cloud.google.com with the **Google Forms API** enabled, and add the redirect URI `http://127.0.0.1:8317/` (the app runs a loopback listener on that port during sign-in). Put the client ID + secret into `.env` and rebuild. A normal Gmail works; the consent screen can stay in Testing mode with your account as a test user.

### Notes

- **OGG** decoding falls back to `ffmpeg` if AVFoundation can't read it (`brew install ffmpeg`); every other format decodes natively.
- Settings → SenseVoice encoder defaults to FP16 on the ANE; `ltctl transcribe --precision int8` uses the half-size encoder (CLI: `ltctl transcribe <file> [--lang yue] [--precision int8]`).
- The model cache lives in `~/Library/Application Support/FluidAudio/Models/`.

---

## Web app (self-hosted)

Self-hosted web tool for lesson recordings: upload an audio file → the **SenseVoice** sidecar transcribes it (Cantonese + Mandarin + English, runs on your own hardware) → the transcript appears with timestamps → buttons generate an **AI summary** (via OpenRouter), a **Google Form quiz** (created directly in your Google Drive via the official Forms API), and **Word downloads** of the transcript/summary.

```
browser ──► PHP web app (public/)          the whole UI, OpenRouter, Google Forms,
              │                             Word export, job progress
              │ HTTP (uploads + job polls)
              ▼
           ASR sidecar (asr-service/)      ffmpeg → FSMN-VAD → SenseVoice-Small (FunASR)
```

Everything except speech recognition is plain PHP 8 with no Composer dependencies (needs the `curl` and `zip` extensions). The sidecar is the only Python part and can run on a different machine — set its URL in `.env`.

### Layout

| Path | What it is |
|---|---|
| `macapp/` | **Native Mac app** (SwiftUI + FluidAudio/ANE) — see above |
| `public/` | **Web root** — `index.php` (front controller + API), static assets, `.htaccess` |
| `src/` | PHP libraries: `Llm` (OpenRouter), `GForms` (OAuth + Forms API), `Docx` (Word export), `Jobs` (job store + sidecar proxy) |
| `asr-service/` | Python sidecar: FastAPI + FunASR transcription pipeline |
| `uploads/`, `transcripts/`, `jobs/` | data written by the PHP app (must be writable) |

### One-time setup (~15 min)

#### 1. PHP web app

```bash
cp .env.example .env      # then edit it (keys below)
chmod -R 775 uploads transcripts jobs   # or let PHP create them
```

Requirements: **PHP 8.0+** with `curl`, `zip`, `session` (built-in). For deployment point the web server's **DocumentRoot at `public/`** (Apache: the included `.htaccess` handles routing; nginx: try-files to `index.php`). For a quick local test just run `./run.sh`, which uses PHP's built-in server.

Lesson files are big — make sure PHP accepts them. The bundled `public/.user.ini` sets `upload_max_filesize`/`post_max_size` to 512M for CGI/FPM; with `mod_php` or nginx set the same values in `php.ini`.

#### 2. SenseVoice sidecar (on a machine with ffmpeg + ~4 GB free RAM)

```bash
cd asr-service
python3 -m venv ../.venv
../.venv/bin/pip install -r requirements.txt
./run.sh        # binds 127.0.0.1:8100; first run downloads ~1 GB of models
```

ffmpeg must be on its PATH (`apt install ffmpeg` / `brew install ffmpeg`). Then set `ASR_SERVICE_URL` in the web app's `.env` (default `http://127.0.0.1:8100`; use the machine's IP if the sidecar runs elsewhere, and start it with `ASR_HOST=0.0.0.0` so it accepts remote calls — keep it firewalled, it has no auth).

Optional: pre-download the models so the first start doesn't wait: `.venv/bin/python scripts/pull_models.py` (from the repo root).

**Backends — same SenseVoice model, two runtimes (`ASR_BACKEND`):**

| `ASR_BACKEND` | What | Best for |
|---|---|---|
| `auto` (default) | torch on Metal/MPS machines, onnx elsewhere | everything |
| `onnx` | int8 ONNX runtime, CPU only, transcribes chunks with several workers in parallel | CPU-only servers — ~3-5× faster than torch on CPU |
| `torch` | the original FunASR path | Apple Silicon (Metal), or CUDA machines |

On a CPU-only machine the first start additionally runs a one-time ONNX export of the model (~1–2 min); afterwards startup is fast. `ASR_WORKERS` controls the onnx parallelism (default: cores−1, capped at 4; each worker holds a ~300 MB model copy).

Expected throughput for a **1-hour lesson** (rough): Mac with Metal ~2 min; 4-core VM (Xeon E5-2630 v4, onnx backend, 3 workers) ~6–12 min. Torch on the same VM would be ~30–60 min — leave `ASR_BACKEND=auto` there.

#### 3. Configuration (`.env`)

| Setting | Default | Notes |
|---|---|---|
| `OPENROUTER_API_KEY` | — | required for summary/quiz, from [openrouter.ai/keys](https://openrouter.ai/keys) |
| `OPENROUTER_MODEL` | `deepseek/deepseek-chat` | cheap + strong Chinese. Alternatives: `qwen/qwen3-235b-a22b-instruct`, `z-ai/glm-4.5-air`, or `:free` variants |
| `ASR_SERVICE_URL` | `http://127.0.0.1:8100` | where the PHP app finds the sidecar |
| `ASR_BACKEND` | `auto` | sidecar only: `onnx` (fast CPU) / `torch` (Metal/MPS or CUDA) — see the table above |
| `ASR_WORKERS` | cores−1, max 4 | sidecar only: parallel transcription workers for the onnx backend |
| `ASR_DEVICE` | auto | sidecar torch backend only: `cpu` forces CPU; Metal/MPS is used on Apple Silicon otherwise |
| `ASR_LANGUAGE` | `auto` | sidecar only: fallback when the page selector is on Auto |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | — | needed for the quiz button (see below) |
| `GOOGLE_REDIRECT_URI` | `http://127.0.0.1:8000/` | **must exactly match** an Authorized redirect URI on the Google OAuth client |
| `HOST` / `PORT` | `127.0.0.1` / `8000` | `./run.sh` dev-server bind (unused under Apache/nginx) |

#### 4. Google sign-in for the quiz button (one-time, free)

- In [console.cloud.google.com](https://console.cloud.google.com) create (or pick) a project
- APIs & Services → Library → enable **Google Forms API**
- APIs & Services → Credentials → Create credentials → **OAuth client ID**, type *Web application*
- Authorized redirect URI: your app's root URL exactly, e.g. `https://lessons.example.com/` (locally: `http://127.0.0.1:8000/`) — and put the same value in `.env` as `GOOGLE_REDIRECT_URI`
- Put the client ID + secret into `.env`

No Google Workspace or special account is needed — a normal Gmail works. The consent screen can stay in "Testing" mode; add your own account as a test user. Every quiz click opens Google's own sign-in/consent popup — you approve each time; nothing is kept signed in between quizzes (the token file `google_token.json` is deleted after each quiz). *(The Mac app keeps you signed in instead — see its section above.)*

### Daily use (web)

```bash
asr-service/run.sh   # terminal 1 (or a systemd service)
./run.sh             # terminal 2 (or Apache/nginx in production)
# open http://127.0.0.1:8000
```

1. Drop an MP3 (or WAV/M4A/AAC/OGG/FLAC/MP4) into the page and pick the lesson-audio language (auto / Cantonese / Mandarin / English).
2. The transcript appears at the bottom with timestamps (also saved under `transcripts/`).
3. Then: **✨ AI Summary**, **📝 Generate Google Form Quiz**, **⬇ Word** downloads — the same outputs as the Mac app.

### Production notes (web)

- **systemd** is the clean way to keep both parts alive — one unit for `php -S`/php-fpm, one for the sidecar (`ExecStart=/path/asr-service/run.sh`, `Restart=on-failure`). A sidecar restart drops in-flight transcription jobs (the page tells you to re-upload); finished transcripts are kept by the PHP app.
- The sidecar has **no authentication** — never expose port 8100 to the internet; keep it on localhost or a private network.
- `google_token.json` (written during Google sign-in) should not be web-accessible — with DocumentRoot at `public/` it isn't.
- PHP session cookies carry the OAuth state, so all hosts/ports must share one origin (the normal setup).

### How transcription works (web)

The sidecar converts any input to 16 kHz mono WAV with ffmpeg, then FSMN-VAD finds the speech segments, merges them into chunks of up to 25 seconds, and SenseVoice-Small transcribes each chunk — with timestamps stitched onto a single timeline. On the onnx backend the chunks are transcribed by several workers in parallel; progress shows per-chunk completion either way. *(The Mac app runs the same chunked pipeline: Silero VAD → ≤25 s chunks → SenseVoice on the ANE.)*

### Troubleshooting (web)

- **"The transcription service is not reachable"** — the sidecar isn't running / `ASR_SERVICE_URL` is wrong / a firewall blocks it. Check `curl http://127.0.0.1:8100/health`.
- **"The transcription service restarted and lost this job"** — the sidecar was restarted mid-job; upload again.
- **Uploads > ~2 MB fail** — raise `upload_max_filesize` + `post_max_size` (see `public/.user.ini`).
- **"No speech detected"** — the audio may be silent, corrupted, or an unsupported codec; try re-exporting as MP3/WAV.
- **ONNX export errors on first start** — the one-time model export needs the `onnx`/`onnxscript` packages (both are in `asr-service/requirements.txt`); re-run `pip install -r requirements.txt` if the venv predates them.
- **OpenRouter 401/402** — check the key in `.env` / your OpenRouter credit balance.
- **Quiz sign-in says the redirect URI is wrong** — `GOOGLE_REDIRECT_URI` and the Google Cloud console setting must match the browser URL exactly (scheme, host, port, trailing slash).
- **FunASR/NumPy errors** — the sidecar venv pins `numpy<2` on purpose; don't upgrade it.
- **Word export error about php-zip** — install the `zip` extension (`apt install php-zip`, `brew install php` includes it).

Cost per lesson for the AI parts with the default model: a 1-hour transcript ≈ 15k tokens → roughly HKD 0.05–0.10 per summary or quiz. Transcription is free and runs on your own hardware.
