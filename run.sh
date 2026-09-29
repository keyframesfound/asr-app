#!/bin/bash
# Lesson Transcriber — starts the web app at http://127.0.0.1:8000
# Run with:  ./run.sh   (keep this terminal open; Ctrl+C stops the server)

cd "$(dirname "$0")" || exit 1

if lsof -ti :8000 >/dev/null 2>&1; then
  echo "Already running → http://127.0.0.1:8000"
  exit 0
fi

echo "Starting Lesson Transcriber → http://127.0.0.1:8000  (Ctrl+C to stop)"
exec .venv/bin/python -m app.main
