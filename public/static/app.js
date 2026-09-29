const $ = (id) => document.getElementById(id);

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
  setProgress(null, "Uploading…", true);

  const form = new FormData();
  form.append("file", file);
  form.append("lang", $("audioLang").value);

  let data;
  try {
    const res = await fetch("/api/upload", { method: "POST", body: form });
    if (!res.ok) throw new Error((await res.json().catch(() => null))?.detail || `Upload failed (${res.status})`);
    data = await res.json();
  } catch (err) {
    progressWrap.hidden = true;
    showError(String(err.message || err));
    return;
  }
  pollJob(data.job_id);
}

async function pollJob(jobId) {
  while (true) {
    let job;
    try {
      const res = await fetch(`/api/jobs/${jobId}`);
      if (res.status === 404) {
        progressWrap.hidden = true;
        showError(
          "The server was restarted and this transcription was lost. Please upload the file again."
        );
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
      job.indeterminate ? null : job.progress || 0,
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
  const box = $("transcript");
  box.innerHTML = "";
  transcriptLines = segments.map((seg) => `[${fmtTs(seg.start)}] ${seg.text}`);
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

$("btnSummary").addEventListener("click", async (e) => {
  clearError();
  const btn = e.target;
  btn.disabled = true;
  const original = btn.textContent;
  btn.textContent = "Summarising…";
  $("summaryCard").hidden = false;
  $("summary").innerHTML = '<p class="hint">Working on it — this takes a few seconds…</p>';
  try {
    const res = await postJSON("/api/summary", {
      transcript: transcriptLines.join("\n"),
      lang: $("outLang").value,
      title: currentFile ? currentFile.name : "",
    });
    lastSummaryMd = res.summary;
    $("summary").innerHTML = renderMarkdown(res.summary);
  } catch (err) {
    $("summaryCard").hidden = true;
    showError(String(err.message || err));
  } finally {
    btn.disabled = false;
    btn.textContent = original;
  }
});

$("copySummary").addEventListener("click", (e) =>
  copyText($("summary").innerText, e.target)
);

/* ---------- quiz / Google Form ---------- */

let pendingQuiz = null;   // {title, description, questions} waiting to become a form
let pendingAuthState = ""; // single-use proof that this quiz's Google sign-in completed
let lastFormUrl = "";
let consentWindow = null;
let consentWatch = null;

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
  setQuizStatus(
    `Done — ${data.count}-question quiz created in your Google Drive. Share the student link with your class.`
  );
  $("quizCard").scrollIntoView({ behavior: "smooth", block: "start" });
}

$("btnQuiz").addEventListener("click", async (e) => {
  clearError();
  const btn = e.target;
  const original = btn.textContent;
  btn.disabled = true;
  btn.textContent = "Writing questions…";
  $("quizCard").hidden = false;
  $("quizActions").hidden = true;
  $("quizRetry").hidden = true;
  pendingAuthState = ""; // a new quiz always starts a fresh Google sign-in
  setQuizStatus("Generating questions…");
  try {
    const res = await postJSON("/api/quiz", {
      transcript: transcriptLines.join("\n"),
      lang: $("outLang").value,
      count: parseInt($("quizCount").value, 10),
      title: currentFile ? currentFile.name : "",
    });
    pendingQuiz = { title: res.title, description: res.description, questions: res.questions };
    await createForm();
  } catch (err) {
    quizFailure(String(err.message || err));
  } finally {
    btn.disabled = false;
    btn.textContent = original;
  }
});

async function createForm() {
  setQuizStatus("Creating the form in your Google Drive…");
  const res = await fetch("/api/forms", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...pendingQuiz, auth_state: pendingAuthState }),
  });
  if (res.status === 401) {
    const data = await res.json().catch(() => null);
    if (!data?.auth_url) throw new Error("Google sign-in is required but the sign-in URL was missing.");
    pendingAuthState = data.auth_state || "";
    openConsent(data.auth_url);
    return; // resumes automatically when the popup posts "oauth-done"
  }
  if (!res.ok) {
    const detail = (await res.json().catch(() => null))?.detail;
    throw new Error(typeof detail === "string" ? detail : `Request failed (${res.status})`);
  }
  quizSuccess(await res.json());
}

function openConsent(url) {
  setQuizStatus("Waiting for Google sign-in — approve access in the pop-up window…");
  consentWindow = window.open(url, "googleSignIn", "width=520,height=680");
  if (consentWindow) {
    startConsentWatch();
    return;
  }
  // Pop-up blocked: fall back to a user-clicked link.
  setQuizStatus("Pop-up blocked — click to open the Google sign-in page: ");
  const link = document.createElement("a");
  link.href = url;
  link.textContent = "Sign in with Google";
  link.addEventListener("click", (ev) => {
    ev.preventDefault();
    openConsent(url);
  });
  $("quizStatus").append(link);
}

function startConsentWatch() {
  clearInterval(consentWatch);
  consentWatch = setInterval(() => {
    if (consentWindow && consentWindow.closed) {
      clearInterval(consentWatch);
      // If sign-in had succeeded the popup would have messaged us first.
      if (pendingQuiz && $("quizActions").hidden) {
        quizFailure("The sign-in window was closed. Click Retry to try again.");
      }
    }
  }, 500);
}

window.addEventListener("message", (e) => {
  if (e.origin !== window.location.origin || !pendingQuiz) return;
  if (e.data?.type === "oauth-done") {
    clearInterval(consentWatch);
    createForm().catch((err) => quizFailure(String(err.message || err)));
  } else if (e.data?.type === "oauth-error") {
    clearInterval(consentWatch);
    quizFailure("Google sign-in failed or was cancelled. Click Retry to try again.");
  }
});

$("quizRetry").addEventListener("click", () => {
  $("quizRetry").hidden = true;
  createForm().catch((err) => quizFailure(String(err.message || err)));
});

$("copyQuizLink").addEventListener("click", (e) => copyText(lastFormUrl, e.target));

/* ---------- Word downloads ---------- */

$("docxTranscript").addEventListener("click", (e) => downloadDocx("transcript", e.target));
$("docxSummary").addEventListener("click", (e) => downloadDocx("summary", e.target));

async function downloadDocx(kind, btn) {
  const text = kind === "transcript" ? transcriptLines.join("\n") : lastSummaryMd;
  if (!text || !text.trim()) {
    showError(kind === "summary" ? "Generate a summary first." : "Nothing to export yet.");
    return;
  }
  if (btn) {
    btn.disabled = true;
    var original = btn.textContent;
    btn.textContent = "Preparing…";
  }
  try {
    const res = await fetch("/api/docx", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind,
        text,
        title: currentFile ? currentFile.name : "lesson",
      }),
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
    if (btn) {
      btn.disabled = false;
      btn.textContent = original;
    }
  }
}

/* ---------- helpers ---------- */

async function postJSON(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const detail = (await res.json().catch(() => null))?.detail;
    throw new Error(detail || `Request failed (${res.status})`);
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

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

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
  for (const line of md.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
      if (!inList) {
        out.push("<ul>");
        inList = true;
      }
      out.push(`<li>${inline(trimmed.slice(2))}</li>`);
      continue;
    }
    if (inList) {
      out.push("</ul>");
      inList = false;
    }
    if (!trimmed) continue;
    if (trimmed.startsWith("### ")) out.push(`<h4>${inline(trimmed.slice(4))}</h4>`);
    else if (trimmed.startsWith("## ")) out.push(`<h3>${inline(trimmed.slice(3))}</h3>`);
    else if (trimmed.startsWith("# ")) out.push(`<h3>${inline(trimmed.slice(2))}</h3>`);
    else out.push(`<p>${inline(trimmed)}</p>`);
  }
  if (inList) out.push("</ul>");
  return out.join("\n");
}
