"""Google Forms API client — builds quiz forms directly in the teacher's Drive.

Uses OAuth 2.0 with the forms.body scope. Every quiz demands its own fresh
Google sign-in: the browser visits Google's consent page in a popup, and the
exchanged token lives only long enough to create that one form before it is
discarded — so the next quiz has to sign in again.
"""

import html
import json
import os
import secrets
import time
from urllib.parse import urlencode

import httpx
from dotenv import load_dotenv

load_dotenv()

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_FORMS_API = "https://forms.googleapis.com/v1"
SCOPE = "https://www.googleapis.com/auth/forms.body"
# Must match the "Authorized redirect URI" on the Google Cloud OAuth client exactly.
REDIRECT_URI = os.environ.get("GOOGLE_REDIRECT_URI", "http://127.0.0.1:8000/")

_TOKEN_FILE = os.path.join(ROOT, "google_token.json")
_STATE_TTL = 600  # seconds a pending sign-in round-trip stays valid
_FRESH_TTL = 300  # seconds a just-completed sign-in counts as proof for one form request

# Single-use state values for OAuth round-trips currently in flight.
_pending_states: dict[str, float] = {}
# States whose sign-in just completed; each is claimable exactly once, by the
# /api/forms retry that triggered it.
_completed_states: dict[str, float] = {}


class NotSignedIn(RuntimeError):
    """No usable Google token — the browser must visit the consent URL first."""


def _client_id() -> str:
    return os.environ.get("GOOGLE_CLIENT_ID", "").strip()


def _client_secret() -> str:
    return os.environ.get("GOOGLE_CLIENT_SECRET", "").strip()


def is_configured() -> bool:
    return bool(_client_id() and _client_secret())


def has_token() -> bool:
    token = _load_token()
    return bool(token and token.get("refresh_token"))


# ---------- OAuth round-trip ----------

def issue_state() -> str:
    now = time.time()
    for key, exp in list(_pending_states.items()):
        if exp < now:
            del _pending_states[key]
    for key, exp in list(_completed_states.items()):
        if exp < now:
            del _completed_states[key]
    state = secrets.token_urlsafe(24)
    _pending_states[state] = now + _STATE_TTL
    return state


def claim_fresh_signin(state: str) -> bool:
    """True if `state` completed a Google sign-in just now (consumed on use)."""
    return _completed_states.pop(state, 0) >= time.time()


def build_auth_url(state: str) -> str:
    params = {
        "client_id": _client_id(),
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",  # we need a refresh token, not just the 1-hour access token
        # Re-ask for the account and the consent on every single sign-in.
        "prompt": "consent select_account",
        "state": state,
    }
    return f"{_AUTH_URL}?{urlencode(params)}"


def oauth_callback_html(code: str, state: str, error: str) -> str:
    """Handle the redirect back from Google's consent page (rendered in the popup)."""
    if error:
        message, event = f"Google sign-in failed: {error}", "oauth-error"
    elif not code:
        message, event = "Google sign-in failed: no authorisation code was returned.", "oauth-error"
    elif not _consume_state(state):
        message, event = "Sign-in session expired — close this window and try again.", "oauth-error"
    else:
        try:
            exchange_code(code)
            # Mark this round-trip as freshly signed in, claimable by one form request.
            _completed_states[state] = time.time() + _FRESH_TTL
            message, event = "Google sign-in complete — you can close this window.", "oauth-done"
        except RuntimeError as exc:
            message, event = f"Google sign-in failed: {exc}", "oauth-error"

    message = html.escape(message)
    return f"""<!doctype html>
<html><body>
<p>{message}</p>
<script>
  try {{
    window.opener && window.opener.postMessage({{ type: "{event}" }}, "*");
  }} catch (e) {{}}
  setTimeout(function () {{ window.close(); }}, 400);
</script>
</body></html>"""


def _consume_state(state: str) -> bool:
    expiry = _pending_states.pop(state, 0)
    return expiry >= time.time()


def exchange_code(code: str) -> None:
    res = httpx.post(
        _TOKEN_URL,
        data={
            "client_id": _client_id(),
            "client_secret": _client_secret(),
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": REDIRECT_URI,
        },
        timeout=30,
    )
    if res.status_code != 200:
        detail = _json_get(res, "error_description") or res.text
        raise RuntimeError(f"token exchange failed ({res.status_code}): {detail}")
    data = res.json()
    previous = _load_token() or {}
    _save_token(
        {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token") or previous.get("refresh_token", ""),
            "expires_at": time.time() + int(data.get("expires_in", 3600)),
        }
    )


# ---------- token cache ----------

def _load_token() -> dict | None:
    try:
        with open(_TOKEN_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _save_token(token: dict) -> None:
    with open(_TOKEN_FILE, "w", encoding="utf-8") as fh:
        json.dump(token, fh)
    try:
        os.chmod(_TOKEN_FILE, 0o600)
    except OSError:
        pass


def forget_token() -> None:
    try:
        os.remove(_TOKEN_FILE)
    except OSError:
        pass


def _bearer() -> str:
    token = _load_token()
    if not token or not token.get("access_token"):
        raise NotSignedIn("no Google sign-in yet")
    if token.get("expires_at", 0) - 60 < time.time():
        token = _refresh(token)
    return token["access_token"]


def _refresh(token: dict) -> dict:
    res = httpx.post(
        _TOKEN_URL,
        data={
            "client_id": _client_id(),
            "client_secret": _client_secret(),
            "refresh_token": token["refresh_token"],
            "grant_type": "refresh_token",
        },
        timeout=30,
    )
    if res.status_code != 200:
        forget_token()
        raise NotSignedIn("sign-in has expired, please sign in again")
    data = res.json()
    token.update(
        access_token=data["access_token"],
        expires_at=time.time() + int(data.get("expires_in", 3600)),
    )
    _save_token(token)
    return token


def _json_get(res: httpx.Response, key: str) -> str:
    try:
        return str(res.json().get(key, "") or "")
    except ValueError:
        return ""


# ---------- form creation ----------

def create_quiz_form(title: str, description: str, questions: list[dict]) -> dict:
    """Create a quiz-mode form; returns {form_id, form_url, edit_url}."""
    headers = {"Authorization": f"Bearer {_bearer()}"}
    try:
        with httpx.Client(timeout=60) as client:
            res = client.post(
                f"{_FORMS_API}/forms",
                headers=headers,
                json={"info": {"title": title or "Lesson Quiz"}},
            )
            form = _check(res)
            form_id = form["formId"]

            # Quiz mode must be on before graded items exist.
            res = client.post(
                f"{_FORMS_API}/forms/{form_id}:batchUpdate",
                headers=headers,
                json={
                    "requests": [
                        {
                            "updateFormInfo": {
                                "info": {"description": description},
                                "updateMask": "description",
                            }
                        },
                        {
                            "updateSettings": {
                                "settings": {
                                    "quizSettings": {"isQuiz": True},
                                    "emailCollectionType": "DO_NOT_COLLECT",
                                },
                                "updateMask": "quizSettings,emailCollectionType",
                            }
                        },
                    ]
                },
            )
            _check(res)

            res = client.post(
                f"{_FORMS_API}/forms/{form_id}:batchUpdate",
                headers=headers,
                json={
                    "requests": [
                        {"createItem": {"item": _question_item(q), "location": {"index": i}}}
                        for i, q in enumerate(questions)
                    ]
                },
            )
            _check(res)
    except httpx.HTTPError as exc:
        raise RuntimeError(f"could not reach the Google Forms API: {exc}") from exc

    return {
        "form_id": form_id,
        "form_url": form["responderUri"],
        "edit_url": f"https://docs.google.com/forms/d/{form_id}/edit",
    }


def _check(res: httpx.Response) -> dict:
    if res.status_code >= 400:
        try:
            message = res.json().get("error", {}).get("message") or res.text
        except ValueError:
            message = res.text
        raise RuntimeError(f"Google Forms API error ({res.status_code}): {message}")
    return res.json()


def _question_item(q: dict) -> dict:
    grading = {
        "pointValue": 1,
        "correctAnswers": {"answers": [{"value": q["options"][q["answer"]]}]},
    }
    if q.get("explanation"):
        grading["whenWrong"] = {"text": q["explanation"]}
    return {
        "title": q["question"],
        "questionItem": {
            "question": {
                "required": True,
                "choiceQuestion": {
                    "type": "RADIO",
                    "options": [{"value": option} for option in q["options"]],
                },
                "grading": grading,
            }
        },
    }
