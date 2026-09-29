# Lesson Transcriber

Self-hosted web tool for lesson recordings: upload an audio file → the **SenseVoice** sidecar transcribes it (Cantonese + Mandarin + English, runs on your own hardware) → the transcript appears with timestamps → buttons generate an **AI summary** (via OpenRouter), a **Google Form quiz** (created directly in your Google Drive via the official Forms API), and **Word downloads** of the transcript/summary.

The app is now **PHP + one small Python sidecar**:

```
browser ──► PHP web app (public/)          the whole UI, OpenRouter, Google Forms,
              │                             Word export, job progress
              │ HTTP (uploads + job polls)
              ▼
           ASR sidecar (asr-service/)      ffmpeg → FSMN-VAD → SenseVoice-Small (FunASR)
```

Everything except speech recognition is plain PHP 8 with no Composer dependencies (needs the `curl` and `zip` extensions). The sidecar is the only Python part and can run on a different machine — set its URL in `.env`.

## Layout

| Path | What it is |
|---|---|
| `public/` | **Web root** — `index.php` (front controller + API), static assets, `.htaccess` |
| `src/` | PHP libraries: `Llm` (OpenRouter), `GForms` (OAuth + Forms API), `Docx` (Word export), `Jobs` (job store + sidecar proxy) |
| `asr-service/` | Python sidecar: FastAPI + FunASR transcription pipeline |
| `uploads/`, `transcripts/`, `jobs/` | data written by the PHP app (must be writable) |

## One-time setup (~15 min)

### 1. PHP web app

```bash
cp .env.example .env      # then edit it (keys below)
chmod -R 775 uploads transcripts jobs   # or let PHP create them
```

Requirements: **PHP 8.0+** with `curl`, `zip`, `session` (built-in). For deployment point the web server's **DocumentRoot at `public/`** (Apache: the included `.htaccess` handles routing; nginx: try-files to `index.php`). For a quick local test just run `./run.sh`, which uses PHP's built-in server.

Lesson files are big — make sure PHP accepts them. The bundled `public/.user.ini` sets `upload_max_filesize`/`post_max_size` to 512M for CGI/FPM; with `mod_php` or nginx set the same values in `php.ini`.

### 2. SenseVoice sidecar (on a machine with ffmpeg + ~4 GB free RAM)

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

### 3. Configuration (`.env`)

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

### 4. Google sign-in for the quiz button (one-time, free)

- In [console.cloud.google.com](https://console.cloud.google.com) create (or pick) a project
- APIs & Services → Library → enable **Google Forms API**
- APIs & Services → Credentials → Create credentials → **OAuth client ID**, type *Web application*
- Authorized redirect URI: your app's root URL exactly, e.g. `https://lessons.example.com/` (locally: `http://127.0.0.1:8000/`) — and put the same value in `.env` as `GOOGLE_REDIRECT_URI`
- Put the client ID + secret into `.env`

No Google Workspace or special account is needed — a normal Gmail works. The consent screen can stay in "Testing" mode; add your own account as a test user. Every quiz click opens Google's own sign-in/consent popup — you approve each time; nothing is kept signed in between quizzes (the token file `google_token.json` is deleted after each quiz).

## Daily use

```bash
asr-service/run.sh   # terminal 1 (or a systemd service)
./run.sh             # terminal 2 (or Apache/nginx in production)
# open http://127.0.0.1:8000
```

1. Drop an MP3 (or WAV/M4A/AAC/OGG/FLAC/MP4) into the page and pick the lesson-audio language (auto / Cantonese / Mandarin / English).
2. The transcript appears at the bottom with timestamps (also saved under `transcripts/`).
3. Then:
   - **✨ AI Summary** — overview, key points, key terms, examples, follow-ups.
   - **📝 Generate Google Form Quiz** — writes the questions, then creates a quiz-mode Google Form in your Drive (1 point per question, correct answers marked, explanations shown on wrong answers). A Google sign-in popup appears every time; then the card shows the **student link** (share this) and an **Edit form** link.
   - **⬇ Word** on the transcript and summary cards — downloads formatted `.docx` files.

## Production notes

- **systemd** is the clean way to keep both parts alive — one unit for `php -S`/php-fpm, one for the sidecar (`ExecStart=/path/asr-service/run.sh`, `Restart=on-failure`). A sidecar restart drops in-flight transcription jobs (the page tells you to re-upload); finished transcripts are kept by the PHP app.
- The sidecar has **no authentication** — never expose port 8100 to the internet; keep it on localhost or a private network.
- `google_token.json` (written during Google sign-in) should not be web-accessible — with DocumentRoot at `public/` it isn't.
- PHP session cookies carry the OAuth state, so all hosts/ports must share one origin (the normal setup).

## How transcription works

The sidecar converts any input to 16 kHz mono WAV with ffmpeg, then FSMN-VAD finds the speech segments, merges them into chunks of up to 25 seconds, and SenseVoice-Small transcribes each chunk — with timestamps stitched onto a single timeline. On the onnx backend the chunks are transcribed by several workers in parallel; progress shows per-chunk completion either way.

## Troubleshooting

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
