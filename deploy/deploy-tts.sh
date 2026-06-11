#!/usr/bin/env bash
# deploy-tts.sh — pull the qwen3-tts-server image from ghcr.io and serve a
# Qwen3-TTS variant of the user's choice on port 8002.
#
# NOTE: this deploys the LEGACY v0.1 image (non-streaming, qwen-tts SDK,
# VoiceDesign only). For the v0.3.0 streaming build (faster-qwen3-tts
# engine, VoiceDesign + VoiceClone) see README.md →
# "Deploying the v0.3.0 streaming build".
#
# Usage:
#   bash deploy/deploy-tts.sh                  # interactive picker
#   QWEN_TTS_MODEL=Qwen/... bash deploy/deploy-tts.sh   # non-interactive
#
# Defaults:
#   IMAGE        ghcr.io/aeon-7/qwen3-tts-server:latest
#   MODEL        Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign  (validated default)
#   TOKENIZER    Qwen/Qwen3-TTS-Tokenizer-12Hz         (shared by all TTS variants)
#   PORT         8002
#   NETWORK      aeon-stack  (created if missing)
#   HF_CACHE     ${HOME}/.cache/huggingface
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/aeon-7/qwen3-tts-server:latest}"
PORT="${PORT:-8002}"
NETWORK="${NETWORK:-aeon-stack}"
HF_CACHE="${HF_CACHE:-${HOME}/.cache/huggingface}"
CONTAINER="${CONTAINER:-qwen3-tts}"
DEFAULT_VOICE="${QWEN_TTS_DEFAULT_VOICE:-A neutral, friendly adult voice with clear pronunciation, moderate pace, and natural intonation.}"

# ── model picker ─────────────────────────────────────────────────────────────
declare -a TTS_VARIANTS=(
  "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign|1.7B|VoiceDesign  — natural-language voice description (✅ validated default)"
  "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice|1.7B|CustomVoice  — 9 fixed premium speakers + instruction control"
  "Qwen/Qwen3-TTS-12Hz-1.7B-Base       |1.7B|Base         — 3-second zero-shot voice clone / fine-tune base"
  "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice|0.6B|CustomVoice  — same 9 speakers, smaller / faster, no instruct"
  "Qwen/Qwen3-TTS-12Hz-0.6B-Base       |0.6B|Base         — smallest clone / fine-tune base, no instruct"
)

pick_model() {
  if [[ -n "${QWEN_TTS_MODEL:-}" ]]; then
    echo "[deploy-tts] Using QWEN_TTS_MODEL from env: ${QWEN_TTS_MODEL}" >&2
    return
  fi
  echo "Pick a Qwen3-TTS variant:" >&2
  local i=1
  for v in "${TTS_VARIANTS[@]}"; do
    printf "  %d) %s\n" "$i" "$(echo "$v" | awk -F'|' '{printf "%-40s  %-4s  %s", $1, $2, $3}')" >&2
    i=$((i+1))
  done
  echo >&2
  read -rp "Choice [1, default=1]: " choice
  choice="${choice:-1}"
  QWEN_TTS_MODEL="$(echo "${TTS_VARIANTS[$((choice-1))]}" | cut -d'|' -f1 | xargs)"
  echo "[deploy-tts] Selected: ${QWEN_TTS_MODEL}" >&2
}

# ── prep ─────────────────────────────────────────────────────────────────────
pick_model
QWEN_TTS_TOKENIZER="${QWEN_TTS_TOKENIZER:-Qwen/Qwen3-TTS-Tokenizer-12Hz}"

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"

docker pull "$IMAGE"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# ── run ──────────────────────────────────────────────────────────────────────
docker run -d --name "$CONTAINER" \
  --runtime nvidia \
  --network "$NETWORK" \
  -p "${PORT}:8002" \
  --shm-size=4gb \
  --restart unless-stopped \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e QWEN_TTS_MODEL="$QWEN_TTS_MODEL" \
  -e QWEN_TTS_TOKENIZER="$QWEN_TTS_TOKENIZER" \
  -e QWEN_TTS_DEFAULT_VOICE="$DEFAULT_VOICE" \
  ${HF_TOKEN:+-e HF_TOKEN="$HF_TOKEN"} \
  "$IMAGE"

cat <<EOF

[deploy-tts] Container '${CONTAINER}' started on port ${PORT}.
[deploy-tts] Model:     ${QWEN_TTS_MODEL}
[deploy-tts] Tokenizer: ${QWEN_TTS_TOKENIZER}
[deploy-tts] Network:   ${NETWORK}

First request will download the model (cached at ${HF_CACHE}) and warm up;
expect 1-2 minutes the very first time. Health check:

  curl http://localhost:${PORT}/health

Synthesize:

  curl -X POST http://localhost:${PORT}/v1/audio/speech \\
    -H 'Content-Type: application/json' \\
    -d '{"input":"Hello world","response_format":"wav"}' \\
    --output speech.wav

Tail logs:  docker logs -f ${CONTAINER}
EOF
