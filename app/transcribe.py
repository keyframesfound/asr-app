"""Local transcription pipeline: SenseVoice-Small + FSMN-VAD (FunASR, runs on this Mac).

Jobs run in background threads; the frontend polls GET /api/jobs/{id} for progress.
"""

import os
import subprocess
import threading
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPLOADS = os.path.join(ROOT, "uploads")
TRANSCRIPTS = os.path.join(ROOT, "transcripts")
os.makedirs(UPLOADS, exist_ok=True)
os.makedirs(TRANSCRIPTS, exist_ok=True)

ASR_LANGUAGE = os.environ.get("ASR_LANGUAGE", "auto")


def _pick_device() -> str:
    """ASR_DEVICE env wins; otherwise Metal (MPS) on Apple Silicon, CPU elsewhere."""
    env = os.environ.get("ASR_DEVICE", "").strip()
    if env:
        return env
    try:
        import torch

        if torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"

ALLOWED_EXTS = {".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac", ".mp4"}

# VAD segments are merged into chunks of at most this length for transcription.
MAX_CHUNK_MS = 25_000
MAX_GAP_MS = 800  # gaps shorter than this are bridged inside a chunk


@dataclass
class Job:
    id: str
    filename: str
    language: str
    status: str = "queued"  # queued | converting | transcribing | done | error
    progress: float = 0.0
    stage: str = "Queued"
    indeterminate: bool = False  # no real % available → show animated bar
    segments: list = field(default_factory=list)  # [{start, end, text}] seconds
    error: str = ""


JOBS: dict[str, Job] = {}

_asr = None
_vad = None
_models_lock = threading.Lock()


def _load_models():
    """Lazy singleton load; first call downloads SenseVoiceSmall + fsmn-vad from ModelScope."""
    global _asr, _vad
    with _models_lock:
        if _asr is None:
            from funasr import AutoModel

            device = _pick_device()
            print(f"[asr] loading SenseVoiceSmall on {device}, fsmn-vad on cpu", flush=True)
            _asr = AutoModel(
                model="iic/SenseVoiceSmall",
                trust_remote_code=True,
                device=device,
                disable_update=True,
                disable_pbar=True,
            )
            # fsmn-vad is ~10x slower on MPS than CPU (dispatch overhead on a tiny
            # model), so it stays on CPU regardless of the ASR device.
            _vad = AutoModel(
                model="fsmn-vad",
                device="cpu",
                disable_update=True,
                disable_pbar=True,
            )
        return _asr, _vad


def preload_models() -> None:
    """Load models in a background thread so the first upload skips the wait."""
    def _work():
        try:
            asr, _ = _load_models()
            import numpy as np

            # Warm-up inference compiles the Metal shaders; without it the first
            # real chunk pays a one-off ~1.5s compilation. Pure silence hangs the
            # model, so use quiet noise instead.
            noise = np.random.default_rng(0).uniform(-0.05, 0.05, 16000).astype(np.float32)
            asr.generate(input=noise, cache={}, language="auto", use_itn=True)
            print("[asr] models ready", flush=True)
        except Exception as exc:
            # A real job will retry the load and surface the error properly.
            print(f"[asr] preload failed (will retry on first upload): {exc}", flush=True)

    threading.Thread(target=_work, daemon=True, name="asr-preload").start()


def run_transcription(job_id: str) -> None:
    job = JOBS[job_id]
    try:
        wav_path = os.path.join(UPLOADS, job_id + ".wav")
        job.status, job.stage, job.progress = "converting", "Converting audio…", 2.0
        job.indeterminate = True
        _to_wav_16k_mono(os.path.join(UPLOADS, _find_upload(job_id)), wav_path)

        job.status, job.stage, job.progress = "transcribing", "Loading speech model…", 5.0
        asr, vad = _load_models()

        job.stage, job.progress = "Detecting speech segments…", 8.0
        segments = _vad_segments(vad, wav_path)
        if not segments:
            raise RuntimeError("No speech detected in the audio file.")
        chunks = _merge_chunks(segments)

        audio = _load_audio(wav_path)
        total = len(chunks)
        job.indeterminate = False
        for i, (start_ms, end_ms) in enumerate(chunks):
            text = _transcribe_chunk(asr, audio, start_ms, end_ms, job.language)
            if text:
                job.segments.append(
                    {"start": start_ms / 1000, "end": end_ms / 1000, "text": text}
                )
            job.progress = 10.0 + 88.0 * (i + 1) / total
            job.stage = f"Transcribing… {i + 1}/{total}"
        if not job.segments:
            raise RuntimeError("Transcription produced no text for this audio.")

        _write_transcript_file(job)
        job.status, job.stage, job.progress = "done", "Done", 100.0
    except Exception as exc:  # surface the message to the browser
        job.status, job.stage, job.error = "error", "Failed", str(exc)
        job.indeterminate = False


def _find_upload(job_id: str) -> str:
    for name in os.listdir(UPLOADS):
        if os.path.splitext(name)[0] == job_id:
            return name
    raise RuntimeError("Uploaded file went missing.")


def _to_wav_16k_mono(src: str, dst: str) -> None:
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", src, "-ac", "1", "-ar", "16000", "-vn", dst],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr[-400:]}")


def _vad_segments(vad, wav_path: str) -> list[list[int]]:
    result = vad.generate(input=wav_path, cache={})
    value = result[0].get("value", []) if result else []
    return [[int(s), int(e)] for s, e in value if int(e) > int(s)]


def _merge_chunks(segments: list[list[int]]) -> list[list[int]]:
    chunks: list[list[int]] = []
    current: list[int] | None = None
    for start, end in segments:
        if current is None:
            current = [start, end]
        elif end - current[0] <= MAX_CHUNK_MS and start - current[1] <= MAX_GAP_MS:
            current[1] = end
        else:
            chunks.append(current)
            current = [start, end]
    if current:
        chunks.append(current)
    return chunks


def _load_audio(wav_path: str):
    import numpy as np
    from funasr.utils.load_utils import load_audio_text_image_video

    audio = load_audio_text_image_video(wav_path, fs=16000)
    return np.asarray(audio, dtype=np.float32).reshape(-1)


def _transcribe_chunk(asr, audio, start_ms: int, end_ms: int, language: str) -> str:
    from funasr.utils.postprocess_utils import rich_transcription_postprocess

    # 16 kHz audio → 16 samples per millisecond
    chunk = audio[start_ms * 16 : end_ms * 16]
    if chunk.size == 0:
        return ""
    result = asr.generate(
        input=chunk, cache={}, language=language or "auto", use_itn=True
    )
    raw = result[0]["text"] if result else ""
    return rich_transcription_postprocess(raw).strip()


def _write_transcript_file(job: Job) -> None:
    path = os.path.join(TRANSCRIPTS, job.id + ".txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# {job.filename}\n\n")
        for seg in job.segments:
            f.write(f"[{_fmt_ts(seg['start'])}] {seg['text']}\n")


def _fmt_ts(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"
