"""OpenRouter chat client for the AI summary and quiz generation.

The API key stays server-side (.env) — the browser only ever sees the result.
"""

import json
import os

import httpx
from dotenv import load_dotenv

load_dotenv()

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = os.environ.get("OPENROUTER_MODEL", "deepseek/deepseek-chat")

LANG_INSTRUCTIONS = {
    "zh-HK": (
        "Traditional Chinese as used in Hong Kong (香港繁體). Use Traditional "
        "characters and HK written conventions; keep English technical terms in "
        "English where that is natural for a HK classroom."
    ),
    "zh-CN": "Simplified Chinese (简体中文).",
    "en": "English.",
}


def _api_key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        raise RuntimeError(
            "OpenRouter API key is missing — put OPENROUTER_API_KEY in your .env file."
        )
    return key


def _chat(messages: list[dict], max_tokens: int = 4000) -> str:
    with httpx.Client(timeout=180) as client:
        response = client.post(
            OPENROUTER_URL,
            headers={"Authorization": f"Bearer {_api_key()}"},
            json={
                "model": MODEL,
                "messages": messages,
                "max_tokens": max_tokens,
            },
        )
    if response.status_code == 401:
        raise RuntimeError("OpenRouter rejected the API key (401). Check OPENROUTER_API_KEY in .env.")
    if response.status_code == 402:
        raise RuntimeError("OpenRouter account is out of credits (402).")
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]


def summarize(transcript: str, lang: str) -> str:
    lang_rule = LANG_INSTRUCTIONS.get(lang, LANG_INSTRUCTIONS["zh-HK"])
    system = (
        "You are an experienced teaching assistant who summarises lesson transcripts "
        f"for teachers. Write everything in {lang_rule}\n"
        "Produce a Markdown summary with exactly these sections:\n"
        "## Overview — 2-3 sentences on what the lesson covered\n"
        "## Key Points — the main teaching points, as bullets\n"
        "## Key Terms — important terms/vocabulary with a one-line definition each\n"
        "## Examples — examples or worked problems that came up, briefly\n"
        "## Follow-ups — homework, reminders or next steps, if any were mentioned "
        "(omit the section if there were none)\n"
        "Use only facts from the transcript; never invent content."
    )
    return _chat(
        [
            {"role": "system", "content": system},
            {"role": "user", "content": f"Lesson transcript:\n\n{transcript}"},
        ]
    )


def make_quiz(transcript: str, lang: str, count: int = 10) -> list[dict]:
    count = max(1, min(count, 20))
    lang_rule = LANG_INSTRUCTIONS.get(lang, LANG_INSTRUCTIONS["zh-HK"])
    system = (
        "You are a teacher who writes multiple-choice quizzes from lesson transcripts. "
        f"Write all questions, options and explanations in {lang_rule}\n"
        f"Create exactly {count} multiple-choice questions that test understanding of "
        "the lesson content. Questions must be answerable from the transcript alone, "
        "with mixed difficulty and plausible distractors.\n"
        'Output STRICT JSON only — no markdown fences, no commentary. Format: an array '
        'of objects {"question": string, "options": [exactly 4 strings], '
        '"answer": integer 0-3 (index of the correct option), "explanation": 1-2 '
        "sentence explanation of why the answer is correct}"
    )
    raw = _chat(
        [
            {"role": "system", "content": system},
            {"role": "user", "content": f"Lesson transcript:\n\n{transcript}"},
        ],
        max_tokens=8000,
    )
    return _parse_quiz(raw)


def _parse_quiz(raw: str) -> list[dict]:
    start, end = raw.find("["), raw.rfind("]")
    payload = raw[start : end + 1] if start != -1 and end > start else raw
    try:
        data = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            "The model did not return valid quiz JSON. Try again, or switch "
            "OPENROUTER_MODEL in .env."
        ) from exc
    if not isinstance(data, list):
        raise RuntimeError("Unexpected quiz format from the model.")

    questions = []
    for item in data:
        if not isinstance(item, dict):
            continue
        options = item.get("options")
        answer = item.get("answer")
        if (
            not isinstance(item.get("question"), str)
            or not item["question"].strip()
            or not isinstance(options, list)
            or len(options) != 4
            or not all(isinstance(o, str) and o.strip() for o in options)
            or not isinstance(answer, int)
            or not 0 <= answer <= 3
        ):
            continue
        questions.append(
            {
                "question": item["question"].strip(),
                "options": [o.strip() for o in options],
                "answer": answer,
                "explanation": str(item.get("explanation", "")).strip(),
            }
        )
    if len(questions) < 3:
        raise RuntimeError("The model returned too few valid questions. Try again.")
    return questions
