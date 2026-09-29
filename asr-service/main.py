"""SenseVoice ASR sidecar — transcription jobs only.

The PHP app (public/) owns the UI and every other feature; it forwards uploaded
audio here and mirrors job progress back to the browser. Run with ./run.sh
(default port 8100) and point ASR_SERVICE_URL in the web app's .env at it.
"""

import os
import threading
import uuid
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile

import transcribe
from transcribe import preload_models

load_dotenv()  # picks up ASR_* settings from the repo root .env when present


@asynccontextmanager
async def lifespan(_app: FastAPI):
    preload_models()  # load SenseVoice in the background while the server starts
    yield


app = FastAPI(title="Lesson Transcriber — ASR sidecar", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "backend": transcribe._resolve_backend(), "workers": transcribe._worker_count()}


@app.post("/api/upload")
async def upload(file: UploadFile = File(...), lang: str = Form("auto")) -> dict:
    filename = file.filename or "audio"
    ext = os.path.splitext(filename)[1].lower()
    if ext not in transcribe.ALLOWED_EXTS:
        raise HTTPException(400, f"Unsupported file type '{ext}'. Use MP3, WAV, M4A, AAC, OGG, FLAC or MP4.")

    job_id = uuid.uuid4().hex[:12]
    dest = os.path.join(transcribe.UPLOADS, job_id + ext)
    with open(dest, "wb") as out:
        out.write(await file.read())

    job = transcribe.Job(
        id=job_id,
        filename=filename,
        language=lang if lang in {"auto", "yue", "zh", "en"} else transcribe.ASR_LANGUAGE,
    )
    transcribe.JOBS[job_id] = job
    threading.Thread(target=transcribe.run_transcription, args=(job_id,), daemon=True).start()
    return {"job_id": job_id, "filename": filename}


@app.get("/api/jobs/{job_id}")
def job_status(job_id: str) -> dict:
    job = transcribe.JOBS.get(job_id)
    if job is None:
        raise HTTPException(404, "Unknown job id.")
    return {
        "status": job.status,
        "progress": round(job.progress, 1),
        "stage": job.stage,
        "indeterminate": job.indeterminate,
        "error": job.error,
        "filename": job.filename,
        "segments": job.segments,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("ASR_HOST", "127.0.0.1"),
        port=int(os.environ.get("ASR_PORT", "8100")),
    )
