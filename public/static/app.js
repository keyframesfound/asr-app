const $ = (id) => document.getElementById(id);

const G_SVG = '<svg viewBox="0 0 48 48" width="22" height="22" aria-hidden="true">'
  + '<path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>'
  + '<path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>'
  + '<path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>'
  + '<path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>';

const dropZone = $("dropZone");
const fileInput = $("fileInput");
const progressWrap = $("progressWrap");
const barTrack = $("barTrack");
const barFill = $("barFill");
const pctText = $("pctText");
const elapsedText = $("elapsedText");
const stageText = $("stageText");
const errorText = $("errorText");
const resultSection = $("resultSection");

let currentFile = null;
let transcriptLines = [];
let lastSummaryMd = "";
let startedAt = 0;
let pollRun = 0;

/* ---------- google sign-in gate ---------- */

let signedIn = false;
let authConfigured = true;
let authEmail = "";
let authPopup = null;
let authWatch = null;
let authDone = false;
let authBusy = false;
let pendingAction = null; // re-run automatically once a sign-in completes

async function refreshAuth() {
  try {
    const res = await fetch("/api/auth");
    const data = await res.json();
    authConfigured = !!data.configured;
    signedIn = !!data.signed_in;
    authEmail = String(data.email || "");
  } catch {
    signedIn = false;
  }
  renderAuth();
}

function renderAuth() {
  $("authGate").hidden = false;
  $("authError").hidden = true;
  $("authPopupLink").hidden = true;
  $("btnGoogle").hidden = signedIn || !authConfigured;
  $("btnAuthRetry").hidden = true;
  $("btnSignOut").hidden = !signedIn;
  $("authBadge").innerHTML = signedIn ? '<span class="auth-check">✓</span>' : G_SVG;
  $("btnSummary").disabled = !signedIn;
  $("btnQuiz").disabled = !signedIn;
  if (signedIn) {
    $("authTitle").textContent = authEmail ? `Signed in as ${authEmail}` : "Signed in with Google";
    $("authHint").textContent = "AI summary, quiz generation and Google Forms are unlocked for this browser session.";
  } else if (!authConfigured) {
    $("authTitle").textContent = "Google sign-in isn't set up on this server yet";
    $("authHint").textContent = "Add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to .env (see the README), then reload this page.";
  } else {
    $("authTitle").textContent = "Sign in with Google to use the AI features";
    $("authHint").textContent = "One sign-in per browser session unlocks the AI summary, quiz generation and Google Forms. Your lessons stay on this machine.";
  }
}

async function startSignIn() {
  if (authBusy || signedIn || !authConfigured) return;
  authBusy = true;
  $("btnGoogle").disabled = true;
  $("btnAuthRetry").disabled = true;
  $("authError").hidden = true;
  $("authPopupLink").hidden = true;
  $("authTitle").textContent = "Waiting for Google…";
  $("authHint").textContent = "Approve access in the pop-up window. Closed it by accident? Click Try again for a second go.";
  try {
    const data = await postJSON("/api/auth", {});
    authDone = false;
    openAuthPopup(data.auth_url);
  } catch (err) {
    authFailure(String(err.message || err));
  } finally {
    authBusy = false;
    $("btnGoogle").disabled = false;
    $("btnAuthRetry").disabled = false;
  }
}

function openAuthPopup(url) {
  authPopup = window.open(url, "googleSignIn", "width=520,height=680");
  if (!authPopup) {
    $("authPopupLink").href = url;
    $("authPopupLink").hidden = false;
    authFailure("The pop-up was blocked — open the sign-in page from this link instead.");
    return;
  }
  clearInterval(authWatch);
  authWatch = setInterval(() => {
    if (authPopup && authPopup.closed && !authDone && !signedIn) {
      clearInterval(authWatch);
      authFailure("The Google sign-in window was closed before finishing — click Try again for a second chance.");
    }
  }, 500);
}

function authFailure(message) {
  $("authTitle").textContent = "Sign in with Google to use the AI features";
  $("authHint").textContent = "One sign-in per browser session unlocks the AI summary, quiz generation and Google Forms.";
  $("authError").textContent = message;
  $("authError").hidden = false;
  $("btnAuthRetry").hidden = false;
}

function finishSignIn(email) {
  clearInterval(authWatch);
  signedIn = true;
  authEmail = String(email || authEmail);
  renderAuth();
  const resume = pendingAction;
  pendingAction = null;
  if (resume) resume();
}

/** True when the error is a 401 — flips the gate back to signed-out and arms a resume. */
function handleAuthFailure(err, retry) {
  if (err.status !== 401) return false;
  signedIn = false;
  pendingAction = retry;
  renderAuth();
  $("authError").textContent = "Your Google session ended — sign in again to carry on where you left off.";
  $("authError").hidden = false;
  return true;
}

$("btnGoogle").addEventListener("click", startSignIn);
$("btnAuthRetry").addEventListener("click", startSignIn);
$("btnSignOut").addEventListener("click", async () => {
  try {
    await postJSON("/api/auth/signout", {});
  } catch {}
  signedIn = false;
  authEmail = "";
  renderAuth();
});

window.addEventListener("message", (e) => {
  if (e.origin !== window.location.origin) return;
  if (e.data?.type === "google-auth-done") {
    finishSignIn(String(e.data.email || ""));
    refreshAuth(); // confirm the server-side session state
  } else if (e.data?.type === "google-auth-error") {
    clearInterval(authWatch);
    authFailure(String(e.data.message || "Google sign-in failed."));
  }
});

/* ---------- AI loading overlay ---------- */

const AI_OVERLAYS = {
  summary: {
    title: "AI Summary",
    steps: [
      "Reading the transcript…",
      "Picking out the key ideas…",
      "Structuring the summary…",
      "Polishing the wording…",
      "Still working — long lessons take a little longer…",
    ],
  },
  quiz: {
    title: "Google Form Quiz",
    steps: [
      "Re-reading the lesson…",
      "Drafting the questions…",
      "Writing the answer key…",
      "Checking every question…",
      "Still working — this can take up to a minute…",
    ],
  },
  forms: {
    title: "Google Form Quiz",
    steps: [
      "Contacting Google…",
      "Creating the quiz form…",
      "Adding the questions…",
      "Marking the correct answers…",
      "Still working — Google is taking its time…",
    ],
  },
};

let overlayTimer = null;
let overlayAbort = null;

function showAiOverlay(kind) {
  const spec = AI_OVERLAYS[kind];
  const stepEl = $("aiOverlayStep");
  let i = 0;
  const swap = () => {
    stepEl.textContent = spec.steps[i % spec.steps.length];
    i += 1;
    stepEl.classList.remove("swap");
    void stepEl.offsetWidth; // restart the fade-in animation
    stepEl.classList.add("swap");
  };
  $("aiOverlayTitle").textContent = spec.title;
  swap();
  clearInterval(overlayTimer);
  overlayTimer = setInterval(swap, 2600);
  overlayAbort = new AbortController();
  $("aiOverlay").hidden = false;
}

function hideAiOverlay() {
  clearInterval(overlayTimer);
  overlayTimer = null;
  overlayAbort = null;
  $("aiOverlay").hidden = true;
}

function overlaySignal() {
  return overlayAbort ? overlayAbort.signal : undefined;
}

$("aiOverlayCancel").addEventListener("click", () => {
  if (overlayAbort) overlayAbort.abort();
});

/* ---------- upload + transcription ---------- */

dropZone.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", () => fileInput.files[0] && startUpload(fileInput.files[0]));

["dragover", "dragenter"].forEach((evt) =>
  dropZone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropZone.classList.add("dragging");
  })
);
["dragleave", "dragend", "drop"].forEach((evt) =>
  dropZone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropZone.classList.remove("dragging");
  })
);
dropZone.addEventListener("drop", (e) => {
  const file = e.dataTransfer.files && e.dataTransfer.files[0];
  if (file) startUpload(file);
});

function showError(message) {
  errorText.textContent = message;
  errorText.hidden = false;
}

function clearError() {
  errorText.hidden = true;
  errorText.textContent = "";
}

async function startUpload(file) {
  clearError();
  resultSection.hidden = true;
  $("summaryCard").hidden = true;
  $("quizCard").hidden = true;
  pendingQuiz = null;
  currentFile = file;
  progressWrap.hidden = false;
  startedAt = Date.now();
  setProgress(0, "Uploading…", true);

  const form = new FormData();
  form.append("file", file);
  form.append("lang", $("audioLang").value);

  try {
    const res = await fetch("/api/upload", { method: "POST", body: form });
    if (!res.ok) {
      throw new Error((await res.json().catch(() => null))?.detail || `Upload failed (${res.status})`);
    }
    const data = await res.json();
    pollJob(data.job_id);
  } catch (err) {
    progressWrap.hidden = true;
    showError(String(err.message || err));
  }
}

async function pollJob(jobId) {
  const run = ++pollRun;
  while (run === pollRun) {
    let job;
    try {
      const res = await fetch(`/api/jobs/${jobId}`);
      if (res.status === 404) {
        progressWrap.hidden = true;
        showError("The server was restarted and this transcription was lost. Please upload the file again.");
        return;
      }
      if (!res.ok) {
        await sleep(1500);
        continue;
      }
      job = await res.json();
    } catch {
      await sleep(1500);
      continue;
    }
    if (job.status === "error") {
      progressWrap.hidden = true;
      showError(job.error || "Transcription failed.");
      return;
    }
    if (job.status === "done") {
      setProgress(100, `Done in ${fmtElapsed(Date.now() - startedAt)}`, false);
      setTimeout(() => (progressWrap.hidden = true), 1500);
      renderTranscript(job.segments || []);
      return;
    }
    setProgress(
      job.indeterminate ? 0 : job.progress || 0,
      job.stage || "Working…",
      !!job.indeterminate
    );
    await sleep(1200);
  }
}

function fmtElapsed(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function setProgress(pct, stage, indeterminate) {
  stageText.textContent = stage;
  elapsedText.textContent = fmtElapsed(Date.now() - startedAt);
  pctText.textContent = indeterminate ? "…" : `${Math.round(pct)}%`;
  barTrack.classList.toggle("indeterminate", !!indeterminate);
  barFill.style.width = indeterminate
    ? "100%"
    : `${Math.min(100, Math.max(0, pct))}%`;
}

/* ---------- transcript ---------- */

function fmtTs(seconds) {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function renderTranscript(segments) {
  transcriptLines = segments.map((seg) => `[${fmtTs(seg.start)}] ${seg.text}`);
  const box = $("transcript");
  box.innerHTML = "";
  for (const seg of segments) {
    const line = document.createElement("div");
    line.className = "seg";
    const ts = document.createElement("span");
    ts.className = "ts";
    ts.textContent = fmtTs(seg.start);
    const txt = document.createElement("span");
    txt.textContent = seg.text;
    line.append(ts, txt);
    box.appendChild(line);
  }
  resultSection.hidden = false;
  resultSection.scrollIntoView({ behavior: "smooth", block: "start" });
}

$("copyTranscript").addEventListener("click", (e) => copyText(transcriptLines.join("\n"), e.target));

/* ---------- AI summary ---------- */

$("btnSummary").addEventListener("click", () => {
  clearError();
  if (!signedIn) {
    pendingAction = runSummary;
    startSignIn();
    return;
  }
  runSummary();
});

async function runSummary() {
  const btn = $("btnSummary");
  const original = btn.textContent;
  btn.disabled = true;
  showAiOverlay("summary");
  try {
    const data = await postJSON("/api/summary", {
      transcript: transcriptLines.join("\n"),
      lang: $("outLang").value,
      title: currentFile ? currentFile.name : "",
    }, overlaySignal());
    lastSummaryMd = data.summary;
    $("summary").innerHTML = renderMarkdown(data.summary);
    $("summaryCard").hidden = false;
  } catch (err) {
    if (err.name === "AbortError") {
      showError("Summary cancelled.");
      return;
    }
    if (handleAuthFailure(err, runSummary)) return;
    $("summaryCard").hidden = true;
    showError(String(err.message || err));
  } finally {
    hideAiOverlay();
    btn.disabled = !signedIn;
    btn.textContent = original;
  }
}

$("copySummary").addEventListener("click", (e) => copyText(lastSummaryMd, e.target));

/* ---------- quiz / Google Form ---------- */

let pendingQuiz = null; // {title, description, questions} waiting to become a form
let lastFormUrl = "";

$("btnQuiz").addEventListener("click", () => {
  clearError();
  if (!signedIn) {
    pendingAction = runQuizFlow;
    startSignIn();
    return;
  }
  runQuizFlow();
});

async function runQuizFlow() {
  const btn = $("btnQuiz");
  const original = btn.textContent;
  btn.disabled = true;
  btn.textContent = "Generating quiz…";
  $("quizCard").hidden = false;
  $("quizActions").hidden = true;
  $("quizRetry").hidden = true;
  pendingQuiz = null;
  setQuizStatus("Generating questions…");
  showAiOverlay("quiz");
  try {
    const data = await postJSON("/api/quiz", {
      transcript: transcriptLines.join("\n"),
      lang: $("outLang").value,
      count: parseInt($("quizCount").value, 10),
      title: currentFile ? currentFile.name : "",
    }, overlaySignal());
    pendingQuiz = { title: data.title, description: data.description, questions: data.questions };
    await createForm();
  } catch (err) {
    if (err.name === "AbortError") {
      quizFailure("Cancelled.");
      return;
    }
    if (handleAuthFailure(err, runQuizFlow)) return;
    quizFailure(String(err.message || err));
  } finally {
    hideAiOverlay();
    btn.disabled = !signedIn;
    btn.textContent = original;
  }
}

async function createForm() {
  showAiOverlay("forms");
  try {
    const data = await postJSON("/api/forms", pendingQuiz, overlaySignal());
    quizSuccess(data);
  } catch (err) {
    if (err.name === "AbortError") {
      quizFailure("Cancelled — the form may still appear in your Google Drive.");
      return;
    }
    if (handleAuthFailure(err, () => createForm())) return;
    quizFailure(String(err.message || err));
  } finally {
    hideAiOverlay();
  }
}

function setQuizStatus(text) {
  $("quizStatus").textContent = text;
}

function quizFailure(message) {
  setQuizStatus(message);
  $("quizRetry").hidden = false;
}

function quizSuccess(data) {
  lastFormUrl = data.form_url;
  $("quizOpenLink").href = data.form_url;
  $("quizEditLink").href = data.edit_url;
  $("quizActions").hidden = false;
  setQuizStatus(`Done — ${data.count}-question quiz created in your Google Drive. Share the student link with your class.`);
  $("quizCard").scrollIntoView({ behavior: "smooth", block: "start" });
}

$("quizRetry").addEventListener("click", () => {
  $("quizRetry").hidden = true;
  if (pendingQuiz) createForm();
  else runQuizFlow();
});

$("copyQuizLink").addEventListener("click", (e) => copyText(lastFormUrl, e.target));

/* ---------- Word downloads ---------- */

$("docxTranscript").addEventListener("click", (e) => downloadDocx("transcript", e.target));
$("docxSummary").addEventListener("click", (e) => downloadDocx("summary", e.target));

async function downloadDocx(kind, btn) {
  const text = kind === "transcript" ? transcriptLines.join("\n") : lastSummaryMd;
  if (!text || !text.trim()) {
    showError(kind === "transcript" ? "Nothing to export yet — transcribe a lesson first." : "Generate a summary first.");
    return;
  }
  const original = btn.textContent;
  btn.disabled = true;
  btn.textContent = "Preparing…";
  try {
    const res = await fetch("/api/docx", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ kind, text, title: currentFile ? currentFile.name : "lesson" }),
    });
    if (!res.ok) {
      const detail = (await res.json().catch(() => null))?.detail;
      throw new Error(detail || `Export failed (${res.status})`);
    }
    const blob = await res.blob();
    const base = (currentFile ? currentFile.name : "lesson").replace(/\.[^.]+$/, "");
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${base}-${kind === "transcript" ? "transcript" : "summary"}.docx`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  } catch (err) {
    showError(String(err.message || err));
  } finally {
    btn.disabled = false;
    btn.textContent = original;
  }
}

/* ---------- helpers ---------- */

async function postJSON(url, body, signal) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const detail = (await res.json().catch(() => null))?.detail;
    const err = new Error(detail || `Request failed (${res.status})`);
    err.status = res.status;
    throw err;
  }
  return res.json();
}

async function copyText(text, btn) {
  try {
    await navigator.clipboard.writeText(text);
    if (btn) {
      const original = btn.textContent;
      btn.textContent = "Copied!";
      setTimeout(() => (btn.textContent = original), 1500);
    }
  } catch {
    showError("Clipboard copy failed — select the text manually.");
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* Tiny markdown renderer for the summary (headings, bullets, bold, code). */
function renderMarkdown(md) {
  const esc = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const inline = (s) =>
    esc(s)
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/`([^`]+)`/g, "<code>$1</code>");

  const out = [];
  let inList = false;
  for (const rawLine of String(md).split("\n")) {
    const line = rawLine.trim();
    if (line.startsWith("- ") || line.startsWith("* ")) {
      if (!inList) {
        out.push("<ul>");
        inList = true;
      }
      out.push(`<li>${inline(line.slice(2))}</li>`);
      continue;
    }
    if (inList) {
      out.push("</ul>");
      inList = false;
    }
    if (!line) continue;
    if (line.startsWith("### ")) out.push(`<h4>${inline(line.slice(4))}</h4>`);
    else if (line.startsWith("## ")) out.push(`<h3>${inline(line.slice(3))}</h3>`);
    else if (line.startsWith("# ")) out.push(`<h3>${inline(line.slice(2))}</h3>`);
    else out.push(`<p>${inline(line)}</p>`);
  }
  if (inList) out.push("</ul>");
  return out.join("\n");
}

/* ---------- boot ---------- */

refreshAuth();
