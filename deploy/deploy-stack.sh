#!/usr/bin/env bash
# deploy-stack.sh — bring up the full voice-AI sidecar stack (TTS + ASR) on
# a single host, on a shared Docker bridge so a vLLM main model can join the
# same network.
#
# This deploys ONLY the audio sidecars (TTS:8002, ASR:8001). Bring your own
# vLLM main on port 8000 — recommended pairing:
#   ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3
#   serving Qwen3.6-27B AEON Ultimate Uncensored MTP-XS (NVFP4 + DFlash)
# See README.md → "Recommended full-stack pairing".
#
# Usage:
#   bash deploy/deploy-stack.sh           # interactive: picks default models
#   bash deploy/deploy-stack.sh --yes     # non-interactive, defaults only
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

NETWORK="${NETWORK:-aeon-stack}"

if [[ "${1:-}" == "--yes" ]]; then
  export QWEN_TTS_MODEL="${QWEN_TTS_MODEL:-Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign}"
  export QWEN_ASR_MODEL="${QWEN_ASR_MODEL:-Qwen/Qwen3-ASR-0.6B}"
fi

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"

echo "=== Deploying TTS sidecar (port 8002) ==="
bash "${SCRIPT_DIR}/deploy-tts.sh"

echo
echo "=== Deploying ASR sidecar (port 8001) ==="
bash "${SCRIPT_DIR}/deploy-asr.sh"

cat <<'EOF'

=== Stack up ===

  docker ps --filter network=aeon-stack
  curl http://localhost:8001/health   # ASR
  curl http://localhost:8002/health   # TTS

To add a vLLM main model and complete the AI stack:

  docker run -d --name qwen36-aeon-xs \
    --runtime nvidia --network aeon-stack -p 8000:8000 \
    -v ${HOME}/.cache/huggingface:/root/.cache/huggingface \
    -e NVIDIA_VISIBLE_DEVICES=all \
    ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3 \
    vllm serve aeon-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-MTP-XS \
      --served-model-name qwen36-ultimate-xs \
      --host 0.0.0.0 --port 8000 \
      --gpu-memory-utilization 0.75 \
      --enable-auto-tool-choice --tool-call-parser qwen3_coder \
      --reasoning-parser qwen3 --trust-remote-code

(See docs/ARCHITECTURE.md for the full pairing rationale.)

EOF
