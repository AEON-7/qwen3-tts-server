# agents.md — autonomous deployment runbook

Instructions for an AI agent (Claude Code, OpenClaw skill, or other) to bring
this stack up cleanly on a fresh host. Written so you can follow it without
hunting through README.md.

## Preconditions

Before starting:

1. **Host kind**: The image is built for `aarch64` + `sm_120` (NVIDIA DGX
   Spark / GB10 / Blackwell consumer). On other architectures, rebuild from
   `Dockerfile` with the appropriate base image.
2. **Docker** with the `nvidia` runtime configured. Verify:
   ```bash
   docker info | grep -i runtime    # expect: Runtimes: nvidia runc
   nvidia-smi || nvidia-ctk version  # at least one should respond
   ```
3. **Disk + RAM**: Image is ~35 GB. Expect ~30 GB extra for HF model cache.
   Free RAM ≥ 15 GB before bring-up (image holds ~5 GB resident, models add
   more).
4. **Network**: Outbound HTTPS to `huggingface.co` and `ghcr.io`.

## Decision points

You must commit to these BEFORE running any docker command:

### 1. Which TTS variant?

Default is `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign` (validated). Only deviate if:

- The user said "voice cloning" → switch to `Qwen3-TTS-12Hz-1.7B-Base`.
- The user said "fixed premium speakers" → `Qwen3-TTS-12Hz-1.7B-CustomVoice`.
- The user said "small / fast / cheap" → `Qwen3-TTS-12Hz-0.6B-CustomVoice`.

If unsure: stick with the default. See [docs/MODELS.md](docs/MODELS.md).

### 2. Which ASR variant?

Default is `Qwen/Qwen3-ASR-0.6B` (validated). Only deviate if:

- The user said "best WER / accuracy / SOTA" → switch to `Qwen3-ASR-1.7B`
  AND set `GPU_MEM=0.16` AND warn the user about the larger memory footprint.

### 3. Standalone or paired with vLLM main?

- **Standalone** (TTS+ASR only): Run `bash deploy/deploy-stack.sh --yes`. Done.
- **Paired with vLLM main** (recommended for full voice agents): Bring up
  vLLM main FIRST (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
  recommended Qwen3.6-27B AEON Ultimate command), then run the deploy script.

## Bring-up — non-interactive

```bash
git clone https://github.com/AEON-7/qwen3-tts-server
cd qwen3-tts-server

# defaults (validated 1.7B-VoiceDesign + 0.6B-ASR)
bash deploy/deploy-stack.sh --yes
```

Or fully scripted:

```bash
export QWEN_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign
export QWEN_ASR_MODEL=Qwen/Qwen3-ASR-0.6B
bash deploy/deploy-stack.sh --yes
```

## Verification — wait for ready

Both services have lazy startup. Poll their health endpoints:

```bash
# TTS — model loads on container start; ready in ~10-20 s
until curl -sf -m 2 http://localhost:8002/health 2>/dev/null | grep -q model_loaded; do sleep 2; done
echo "TTS ready"

# ASR — vLLM compiles CUDA graphs; ready in ~30-90 s on first boot
until curl -sf -m 2 http://localhost:8001/health >/dev/null 2>&1; do sleep 5; done
echo "ASR ready"
```

If polling exceeds 5 min, check logs:

```bash
docker logs --tail 50 qwen3-tts
docker logs --tail 50 qwen3-asr
```

Most common failure: ASR exits with `No available memory for the cache
blocks`. Fix:

```bash
docker rm -f qwen3-asr
GPU_MEM=0.10 bash deploy/deploy-asr.sh
```

(Each retry bumps by 0.02; if you've reached 0.20 and it still fails, lower
`MAX_LEN=4096` and try again.)

## Smoke test

```bash
# 1. TTS
curl -sf -X POST http://localhost:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"input":"Hello world","response_format":"wav"}' \
  --output /tmp/agent_smoke.wav
[[ -s /tmp/agent_smoke.wav ]] && echo "TTS ok ($(stat -c%s /tmp/agent_smoke.wav) bytes)" || { echo "TTS FAIL"; exit 1; }

# 2. ASR (round-trip the TTS output)
ASR_OUT=$(curl -sf -X POST http://localhost:8001/v1/audio/transcriptions \
            -F file=@/tmp/agent_smoke.wav -F model=qwen3-asr -F language=en)
echo "$ASR_OUT" | grep -q '"text"' && echo "ASR ok: $ASR_OUT" || { echo "ASR FAIL: $ASR_OUT"; exit 1; }
```

If both pass, the stack is operational.

## Common follow-up tasks

### Wire matrix-voip-agent on a separate host

The recommended topology has the AI stack on Spark and the WebRTC bridge on
a separate host. Point matrix-voip-agent at this stack with the env vars in
[docs/ARCHITECTURE.md → "Integration: matrix-voip-agent"](docs/ARCHITECTURE.md#integration-matrix-voip-agent).
Don't put hardcoded IPs in code — use `SPARK_HOST` as the substitution
variable.

### Pair with the Qwen3.6-27B AEON Ultimate vLLM main

Run the docker command in
[docs/ARCHITECTURE.md → "Recommended LLM main"](docs/ARCHITECTURE.md#recommended-llm-main)
BEFORE running this stack's deploy script. They share the `aeon-stack`
bridge — order matters only if memory is tight (bring up the heavy LLM
first to claim its allocation).

### Switch model variants live

```bash
docker rm -f qwen3-tts
QWEN_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice bash deploy/deploy-tts.sh
```

The HF cache is bind-mounted, so a previously-downloaded variant restarts
instantly.

## Tear-down

```bash
docker rm -f qwen3-tts qwen3-asr
docker network rm aeon-stack 2>/dev/null || true
# HF cache at ${HOME}/.cache/huggingface is preserved.
```

If also removing the LLM main: `docker rm -f qwen36-aeon-xs` first.

## Don'ts

- Don't bind ports other than `8001` and `8002` to public interfaces without
  putting an auth proxy in front. The endpoints accept any `Authorization`
  header (no real auth).
- Don't set `gpu-memory-utilization` above `0.88` on Spark — see
  [DGX Spark gpu-memory-utilization cap](https://github.com/AEON-7/Qwen3.6-NVFP4-DFlash#dgx-spark-gpu_memory-utilization-caps-at-088).
- Don't `pip install vllm[audio]` into a derivative image — the meta-package
  re-resolves and downgrades vLLM core deps (flashinfer-python, apache-tvm-ffi)
  which silently regresses TTS latency by ~5×. The Dockerfile installs only
  `av --no-deps`; soundfile is already pulled in by `qwen-tts`.
- Don't `--no-verify` on git operations against this repo unless explicitly
  asked.

## Output convention for autonomous reports

If you're an agent reporting back to a parent:

```
qwen3-tts-server bring-up: OK
- TTS: <model-id> on :8002 (<wall ms> for "Hello world")
- ASR: <model-id> on :8001 (<wall ms> round-trip)
- bridge: aeon-stack ready
- LLM main: <attached / not attached>  [<model-id if attached>]
```

If FAIL, include the failing health-check output and the last 20 lines of
the failing container's logs.
