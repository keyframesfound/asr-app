#!/bin/zsh
# Stages the speech models (SenseVoice int8 + Silero VAD) into
# macapp/Resources/FluidAudio so build_app.sh bundles them into the .app —
# release builds then never download from HuggingFace. Idempotent: uses the
# local FluidAudio cache first, downloads only what is missing.
#
#   Scripts/fetch_model.sh [--precision fp16|int8] [--force]   (int8 default)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> building ltctl"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"
"$BIN/ltctl" fetch-models Resources/FluidAudio "$@"

echo "==> staged:"
du -sh Resources/FluidAudio/Models/* 2>/dev/null || true
