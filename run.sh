#!/bin/bash
# Lesson Transcriber (PHP) — starts the web app at http://127.0.0.1:${PORT:-8000}
# Run with:  ./run.sh   (keep this terminal open; Ctrl+C stops the server)
# The SenseVoice sidecar must be running too:  asr-service/run.sh

cd "$(dirname "$0")" || exit 1

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"

if lsof -ti ":$PORT" >/dev/null 2>&1; then
  echo "Already running → http://127.0.0.1:$PORT"
  exit 0
fi

set -a; [ -f .env ] && . ./.env; set +a

# PHP's dev server is single-threaded by default; several workers let job
# polling run while an upload is being forwarded.
export PHP_CLI_SERVER_WORKERS="${PHP_CLI_SERVER_WORKERS:-4}"

echo "Starting Lesson Transcriber → http://$HOST:$PORT  (Ctrl+C to stop)"
# The -d flags match public/.user.ini (which the dev server does not read).
exec php -S "$HOST:$PORT" -t public \
  -d upload_max_filesize=512M -d post_max_size=512M \
  -d memory_limit=512M -d max_execution_time=600 \
  public/index.php
