#!/usr/bin/env bash
# deploy-stack.sh — deploy the TTS sidecar and lay out the next-step
# commands for the matching ASR + LLM main, all joined to the same shared
# Docker bridge.
#
# This deploys ONLY the TTS sidecar (port 8002). For the full voice-AI
# stack you also want:
#   - ghcr.io/aeon-7/qwen3-asr-server:latest  on :8001
#     https://github.com/AEON-7/qwen3-asr-server
#   - Your LLM main of choice on :8000
#     Recommended: ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3
#     serving aeon-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-MTP-XS
#     https://github.com/AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash
#
# Usage:
#   bash deploy/deploy-stack.sh           # interactive: pick TTS variant
#   bash deploy/deploy-stack.sh --yes     # non-interactive, defaults
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

NETWORK="${NETWORK:-aeon-stack}"

if [[ "${1:-}" == "--yes" ]]; then
  export QWEN_TTS_MODEL="${QWEN_TTS_MODEL:-Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign}"
fi

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"

echo "=== Deploying TTS sidecar (port 8002) ==="
bash "${SCRIPT_DIR}/deploy-tts.sh"

cat <<'EOF'

=== TTS up ===

  curl http://localhost:8002/health
  docker ps --filter network=aeon-stack

To complete the voice-AI stack:

# 1. ASR sidecar (companion repo: github.com/AEON-7/qwen3-asr-server)
docker run -d --name qwen3-asr \
  --runtime nvidia --network aeon-stack -p 8001:8001 --shm-size=4gb \
  -v ${HOME}/.cache/huggingface:/root/.cache/huggingface \
  -e NVIDIA_VISIBLE_DEVICES=all \
  ghcr.io/aeon-7/qwen3-asr-server:latest

# 2. LLM main — recommended pairing
docker run -d --name qwen36-aeon-xs \
  --runtime nvidia --network aeon-stack -p 8000:8000 --shm-size=4gb \
  -v ${HOME}/.cache/huggingface:/root/.cache/huggingface \
  -e NVIDIA_VISIBLE_DEVICES=all \
  ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3 \
  vllm serve aeon-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-MTP-XS \
    --served-model-name qwen36-ultimate-xs \
    --host 0.0.0.0 --port 8000 \
    --gpu-memory-utilization 0.75 \
    --enable-auto-tool-choice --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3 --trust-remote-code

(Full pairing rationale + tuning: docs/ARCHITECTURE.md)

EOF
