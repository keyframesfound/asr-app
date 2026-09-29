# Lesson Transcriber

Local web tool for lesson recordings: upload an audio file → transcription runs **entirely on your Mac** (SenseVoice-Small, no audio leaves the machine) → transcript appears at the bottom → buttons generate an **AI summary** (via OpenRouter), a **Google Form quiz** (created directly in your Google Drive via the official Forms API), and **Word downloads** of the transcript/summary.

- **Transcription — SenseVoice-Small via FunASR:** offline, handles Cantonese + Mandarin + English. On Apple Silicon it runs on Metal (MPS) automatically; output is identical to CPU but several times faster. First use downloads ~1 GB of models.

## One-time setup (~10 min)

```bash
# 1. Python dependencies (in a local venv)
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 2. Configure
cp .env.example .env
# then edit .env:
#   - OPENROUTER_API_KEY  (for summary + quiz, from https://openrouter.ai/keys)
# Also download the transcription models (~1 GB):
#   .venv/bin/python scripts/pull_models.py

# 3. Google sign-in for the quiz button (one-time, free)
#   - In https://console.cloud.google.com create (or pick) a project
#   - APIs & Services → Library → enable "Google Forms API"
#   - APIs & Services → Credentials → Create credentials → OAuth client ID
#     · Application type: Web application
#     · Authorized redirect URI: exactly  http://127.0.0.1:8000/
#   - Put the client ID + secret into .env as GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
```

No Google Workspace or special account is needed — a normal Gmail works. The consent screen can stay in "Testing" mode; add your own account as a test user. Every quiz click opens Google's own sign-in/consent popup — you pick your account and approve access each time; nothing is kept signed in between quizzes.

ffmpeg is required for audio conversion (`brew install ffmpeg` if missing).

## Daily use

```bash
./run.sh
# open http://127.0.0.1:8000
```

1. Drop an MP3 (or WAV/M4A/AAC/OGG/FLAC/MP4) into the page and pick the lesson-audio language (auto / Cantonese / Mandarin / English).
2. The transcript appears at the bottom with timestamps.
3. Then:
   - **✨ AI Summary** — overview, key points, key terms, examples, follow-ups.
   - **📝 Generate Google Form Quiz** — writes the questions, then creates a quiz-mode Google Form in your Drive (1 point per question, correct answers marked, explanations shown on wrong answers). A Google sign-in popup appears every time — pick your account and approve; then the card shows the **student link** (share this) and an **Edit form** link.
   - **⬇ Word** on the transcript and summary cards — downloads formatted `.docx` files.

Transcripts are also saved as text files under `transcripts/`.

## Configuration (`.env`)

| Setting | Default | Notes |
|---|---|---|
| `OPENROUTER_API_KEY` | — | required for summary/quiz |
| `OPENROUTER_MODEL` | `deepseek/deepseek-chat` | cheap + strong Chinese. Alternatives: `qwen/qwen3-235b-a22b-instruct`, `z-ai/glm-4.5-air`, or `:free` variants |
| `ASR_DEVICE` | auto (Metal/MPS on Apple Silicon) | offline engine only; set `cpu` to force CPU. MPS gives identical output several times faster |
| `ASR_LANGUAGE` | `auto` | offline engine fallback when the page selector is on Auto |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | — | needed for the quiz button; OAuth client whose redirect URI is exactly `http://127.0.0.1:8000/` |
| `HOST` / `PORT` | `127.0.0.1` / `8000` | server bind address — if you change these, the OAuth redirect URI on the Google client must match |

Cost per lesson for the AI parts with the default model: a 1-hour transcript ≈ 15k tokens → roughly HKD 0.05–0.10 per summary or quiz. Transcription is free and offline.

## How transcription works

The app converts any input to 16 kHz mono WAV with ffmpeg, then FSMN-VAD finds the speech segments, merges them into chunks of up to 25 seconds, and SenseVoice-Small transcribes each chunk on Metal (MPS) — with timestamps stitched onto a single timeline. A 1-hour lesson transcribes in a couple of minutes; the progress bar shows per-chunk progress.

## Troubleshooting

- **"No speech detected"** — the audio may be silent, corrupted, or an unsupported codec; try re-exporting as MP3/WAV.
- **OpenRouter 401/402** — check the key in `.env` / your OpenRouter credit balance.
- **FunASR/NumPy errors** (offline engine only) — the venv pins `numpy<2` on purpose; don't upgrade it.
