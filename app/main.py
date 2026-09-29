"""FastAPI app: static page + upload/transcription jobs + OpenRouter endpoints."""

import os
import re
import threading
import uuid
from contextlib import asynccontextmanager

from dotenv import load_dotenv

load_dotenv()

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from app import docx_export, forms, llm, transcribe

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8000"))

@asynccontextmanager
async def lifespan(_app: FastAPI):
    transcribe.preload_models()  # load SenseVoice in the background while the server starts
    yield


app = FastAPI(title="Lesson Transcriber", lifespan=lifespan)


@app.get("/")
def index(request: Request) -> Response:
    # Google's consent page redirects back to the app root with ?code=&state= (or ?error=)
    # — that is the OAuth callback, everything else is the normal UI.
    params = request.query_params
    if "code" in params or "error" in params:
        return HTMLResponse(
            forms.oauth_callback_html(
                params.get("code", ""), params.get("state", ""), params.get("error", "")
            )
        )
    return FileResponse(os.path.join("static", "index.html"))


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


class SummaryRequest(BaseModel):
    transcript: str
    lang: str = "zh-HK"
    title: str = ""


@app.post("/api/summary")
def summary(req: SummaryRequest) -> dict:
    if len(req.transcript.strip()) < 20:
        raise HTTPException(400, "Transcript is empty or too short to summarise.")
    try:
        return {"summary": llm.summarize(req.transcript, req.lang)}
    except RuntimeError as exc:
        raise HTTPException(400, str(exc)) from exc


class QuizRequest(BaseModel):
    transcript: str
    lang: str = "zh-HK"
    count: int = 10
    title: str = ""


@app.post("/api/quiz")
def quiz(req: QuizRequest) -> dict:
    if len(req.transcript.strip()) < 20:
        raise HTTPException(400, "Transcript is empty or too short to quiz on.")
    try:
        questions = llm.make_quiz(req.transcript, req.lang, req.count)
    except RuntimeError as exc:
        raise HTTPException(400, str(exc)) from exc
    title = os.path.splitext(req.title or "Lesson")[0] + " — Quiz"
    description = (
        f"Auto-generated quiz with {len(questions)} questions based on the lesson "
        f"recording '{req.title or 'lesson'}'. 1 point each."
    )
    return {
        "title": title,
        "description": description,
        "questions": questions,
        "count": len(questions),
    }


class FormRequest(BaseModel):
    title: str = ""
    description: str = ""
    questions: list[dict]
    auth_state: str = ""  # single-use proof that this quiz just finished a Google sign-in


def _auth_challenge() -> JSONResponse:
    """401 telling the browser to run a fresh Google sign-in round-trip."""
    state = forms.issue_state()
    return JSONResponse(
        status_code=401,
        content={"auth_url": forms.build_auth_url(state), "auth_state": state},
    )


@app.post("/api/forms")
def create_form(req: FormRequest) -> Response:
    if not forms.is_configured():
        raise HTTPException(
            400,
            "Google sign-in is not set up yet: add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET "
            "to .env (see README).",
        )
    if not req.questions:
        raise HTTPException(400, "No quiz questions to send to Google Forms.")
    # Every quiz needs its own sign-in: without a just-completed sign-in proof,
    # throw away any cached token and start a fresh OAuth round-trip.
    if not forms.claim_fresh_signin(req.auth_state):
        forms.forget_token()
        return _auth_challenge()
    try:
        created = forms.create_quiz_form(req.title or "Lesson Quiz", req.description, req.questions)
    except forms.NotSignedIn:
        return _auth_challenge()
    except RuntimeError as exc:
        raise HTTPException(400, str(exc)) from exc
    forms.forget_token()  # the next quiz must sign in again
    return {**created, "count": len(req.questions)}


class DocxRequest(BaseModel):
    kind: str  # "transcript" | "summary"
    text: str
    title: str = ""


@app.post("/api/docx")
def make_docx(req: DocxRequest) -> Response:
    if req.kind not in {"transcript", "summary"}:
        raise HTTPException(400, "kind must be 'transcript' or 'summary'.")
    if not req.text.strip():
        raise HTTPException(400, "Nothing to export yet.")
    data = docx_export.build_docx(req.kind, req.text, req.title)
    base = re.sub(r"[^\w\u4e00-\u9fff\- ]+", "", os.path.splitext(req.title or "lesson")[0]).strip() or "lesson"
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        headers={"Content-Disposition": f'attachment; filename="{base}-{req.kind}.docx"'},
    )


app.mount("/static", StaticFiles(directory="static"), name="static")

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT)
