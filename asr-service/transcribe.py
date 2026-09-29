"""Local transcription pipeline: SenseVoice-Small + FSMN-VAD.

Two interchangeable ASR backends behind the same pipeline (ASR_BACKEND env):
  - "torch": FunASR AutoModel — the original path; uses Metal (MPS) on Apple Silicon.
  - "onnx":  funasr-onnx int8 — several times faster than torch on CPU-only
             machines (e.g. the Ubuntu VM deployment); runs on CPU only.
"auto" picks torch when Metal is available, else onnx when installed.

The onnx backend transcribes VAD chunks with a small pool of workers, one
model instance per worker (intra_op_num_threads=1), so all cores pull in
parallel. The PHP app polls GET /api/jobs/{id} for progress.
"""

import os
import queue
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.abspath(__file__))
UPLOADS = os.path.join(ROOT, "uploads")
TRANSCRIPTS = os.path.join(ROOT, "transcripts")
os.makedirs(UPLOADS, exist_ok=True)
os.makedirs(TRANSCRIPTS, exist_ok=True)

ASR_LANGUAGE = os.environ.get("ASR_LANGUAGE", "auto")

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

_backend: str | None = None  # "torch" | "onnx", resolved once
_asr = None  # torch SenseVoice model
_vad = None  # fsmn-vad (torch, both backends use it)
_onnx_pool: "queue.Queue | None" = None
_models_lock = threading.Lock()


def _mps_available() -> bool:
    try:
        import torch

        return bool(torch.backends.mps.is_available())
    except Exception:
        return False


def _pick_device() -> str:
    """ASR_DEVICE env wins; otherwise Metal (MPS) on Apple Silicon, CPU elsewhere."""
    env = os.environ.get("ASR_DEVICE", "").strip()
    if env:
        return env
    return "mps" if _mps_available() else "cpu"


def _resolve_backend() -> str:
    """ASR_BACKEND env wins; auto = torch on Metal machines, onnx elsewhere."""
    global _backend
    if _backend is not None:
        return _backend
    env = os.environ.get("ASR_BACKEND", "auto").strip().lower()
    if env in ("onnx", "torch"):
        _backend = env
    elif _mps_available():
        _backend = "torch"
    else:
        try:
            import funasr_onnx  # noqa: F401

            _backend = "onnx"
        except ImportError:
            print(
                "[asr] funasr-onnx is not installed — using the torch backend "
                "(much slower on CPU-only machines). pip install funasr-onnx "
                "for ~3-5x faster CPU transcription",
                flush=True,
            )
            _backend = "torch"
    print(f"[asr] backend: {_backend}", flush=True)
    return _backend


def _worker_count() -> int:
    """Parallel transcription workers (onnx backend: one model instance each)."""
    env = os.environ.get("ASR_WORKERS", "").strip()
    if env.isdigit() and int(env) >= 1:
        return int(env)
    return max(1, min(4, (os.cpu_count() or 1) - 1))


# ---------- model loading ----------


def _load_asr_torch():
    """Torch backend: SenseVoiceSmall via FunASR (MPS on Apple Silicon)."""
    global _asr
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
        return _asr


def _load_vad():
    """fsmn-vad runs on CPU in both backends — it is ~10x slower on MPS
    (dispatch overhead on a tiny model)."""
    global _vad
    with _models_lock:
        if _vad is None:
            from funasr import AutoModel

            _vad = AutoModel(
                model="fsmn-vad",
                device="cpu",
                disable_update=True,
                disable_pbar=True,
            )
        return _vad


def _load_onnx_model():
    from funasr_onnx import SenseVoiceSmall

    # One single-threaded ONNX session per worker; parallelism comes from the
    # worker pool, not from intra-op threading (poor scaling on 4 small cores).
    return SenseVoiceSmall("iic/SenseVoiceSmall", quantize=True, intra_op_num_threads=1)


def _get_onnx_pool() -> queue.Queue:
    global _onnx_pool
    with _models_lock:
        if _onnx_pool is None:
            workers = _worker_count()
            print(f"[asr] loading SenseVoiceSmall onnx (int8) x{workers} workers on cpu", flush=True)
            pool: queue.Queue = queue.Queue()
            for _ in range(workers):
                pool.put(_load_onnx_model())
            _onnx_pool = pool
        return _onnx_pool


def preload_models() -> None:
    """Load models in a background thread so the first upload skips the wait."""
    def _work():
        try:
            import numpy as np

            # Warm-up inference compiles the Metal shaders (torch backend);
            # without it the first real chunk pays a one-off ~1.5s compilation.
            # Pure silence hangs the model, so use quiet noise instead.
            noise = np.random.default_rng(0).uniform(-0.05, 0.05, 16000).astype(np.float32)
            if _resolve_backend() == "onnx":
                pool = _get_onnx_pool()
                model = pool.get()
                try:
                    _transcribe_chunk(model, noise, 0, 1000, "auto")
                finally:
                    pool.put(model)
            else:
                asr = _load_asr_torch()
                asr.generate(input=noise, cache={}, language="auto", use_itn=True)
            print("[asr] models ready", flush=True)
        except Exception as exc:
            # A real job will retry the load and surface the error properly.
            print(f"[asr] preload failed (will retry on first upload): {exc}", flush=True)

    threading.Thread(target=_work, daemon=True, name="asr-preload").start()


# ---------- transcription ----------


def run_transcription(job_id: str) -> None:
    job = JOBS[job_id]
    try:
        wav_path = os.path.join(UPLOADS, job_id + ".wav")
        job.status, job.stage, job.progress = "converting", "Converting audio…", 2.0
        job.indeterminate = True
        _to_wav_16k_mono(os.path.join(UPLOADS, _find_upload(job_id)), wav_path)

        job.status, job.stage, job.progress = "transcribing", "Loading speech model…", 5.0
        pool = None
        asr = None
        if _resolve_backend() == "onnx":
            pool = _get_onnx_pool()
            workers = _worker_count()
        else:
            asr = _load_asr_torch()
            workers = 1
        vad = _load_vad()

        job.stage, job.progress = "Detecting speech segments…", 8.0
        segments = _vad_segments(vad, wav_path)
        if not segments:
            raise RuntimeError("No speech detected in the audio file.")
        chunks = _merge_chunks(segments)

        audio = _load_audio(wav_path)
        total = len(chunks)
        job.indeterminate = False
        results: list = [None] * total  # filled by index → order stays chronological
        done = 0
        lock = threading.Lock()

        def _work(i: int, start_ms: int, end_ms: int) -> None:
            nonlocal done
            model = pool.get() if pool is not None else asr
            try:
                text = _transcribe_chunk(model, audio, start_ms, end_ms, job.language)
            finally:
                if pool is not None:
                    pool.put(model)
            with lock:
                results[i] = text
                done += 1
                job.progress = 10.0 + 88.0 * done / total
                job.stage = f"Transcribing… {done}/{total}"

        executor = ThreadPoolExecutor(max_workers=workers)
        try:
            futures = [executor.submit(_work, i, s, e) for i, (s, e) in enumerate(chunks)]
            for future in as_completed(futures):
                future.result()  # re-raise the first worker error
        except Exception:
            executor.shutdown(wait=False, cancel_futures=True)
            raise
        else:
            executor.shutdown(wait=True)
        for i, text in enumerate(results):
            if text:
                job.segments.append(
                    {"start": chunks[i][0] / 1000, "end": chunks[i][1] / 1000, "text": text}
                )
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
    # Convert next to the destination and atomically take its place — ffmpeg
    # refuses when input and output are the same path, which is exactly the
    # case for uploads that are already .wav files.
    tmp = dst + ".converting.wav"
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", src, "-ac", "1", "-ar", "16000", "-vn", tmp],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise RuntimeError(f"ffmpeg failed: {result.stderr[-400:]}")
    os.replace(tmp, dst)


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
    if _backend == "onnx":
        # textnorm="withitn" is the onnx equivalent of the torch path's use_itn=True
        result = asr(chunk, language=language or "auto", textnorm="withitn")
        raw = result[0] if result else ""
    else:
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
