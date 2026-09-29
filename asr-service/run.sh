#!/bin/bash
# SenseVoice sidecar — the transcription engine the PHP app talks to.
# Run with:  ./run.sh   (first run downloads ~1 GB of models from ModelScope)

cd "$(dirname "$0")" || exit 1

# Source the shared .env first (ASR_* settings live there too), then apply
# defaults. Use ASR_* names only — .env's HOST/PORT belong to the PHP app.
set -a; [ -f ../.env ] && . ../.env; set +a

ASR_HOST="${ASR_HOST:-127.0.0.1}"
ASR_PORT="${ASR_PORT:-8100}"

if lsof -ti ":$ASR_PORT" >/dev/null 2>&1; then
  echo "ASR sidecar already running → http://$ASR_HOST:$ASR_PORT"
  exit 0
fi

PY=python3
[ -x ../.venv/bin/python ] && PY=../.venv/bin/python

echo "Starting ASR sidecar → http://$ASR_HOST:$ASR_PORT  (Ctrl+C to stop)"
exec "$PY" -m uvicorn main:app --host "$ASR_HOST" --port "$ASR_PORT"
