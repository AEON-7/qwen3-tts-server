# agents.md — autonomous deployment runbook

Instructions for an AI agent to bring this TTS sidecar up cleanly on a
fresh host. Self-contained: you don't need to also read README.md.

> **Version note:** this runbook brings up the **legacy v0.1 image**
> contained in this repo (non-streaming, qwen-tts SDK, VoiceDesign
> only). The author's deployed **v0.3.0 streaming build**
> (faster-qwen3-tts engine, VoiceDesign + VoiceClone, `stream: true`,
> `GET /v1/audio/voices`) is documented in
> [README.md](README.md#deploying-the-v030-streaming-build); its source
> publish here is pending. To tell which build you're talking to:
> `curl /health` — v0.3.0 reports `"backend": "faster-qwen3-tts"` plus
> `clone_loaded` / `voice_library` / `sample_rate`; v0.1 reports only
> `{"status":"ok","model_loaded":true}`. The `model_loaded` health grep
> below works for both.

## Preconditions

1. **Host kind**: Image is built for `aarch64` + `sm_120` (NVIDIA DGX Spark
   / GB10 / Blackwell consumer). On other architectures it will run, but
   flash-attn falls back to SDPA at runtime — rebuild from `Dockerfile`
   with the appropriate `FLASH_ATTN_CUDA_ARCHS` if you want native
   flash-attn there too.
2. **Docker** with the `nvidia` runtime configured.
   ```bash
   docker info | grep -i runtime    # expect: Runtimes: nvidia runc
   ```
3. **Disk + RAM**: Image is ~33 GB. Free RAM ≥ 8 GB before bring-up
   (the 1.7B model is ~4 GB CUDA-resident; 0.6B variants ~2 GB).
4. **Network**: Outbound HTTPS to `huggingface.co` and `ghcr.io`.

## Decision points — commit BEFORE running any docker command

### 1. Which TTS variant?

Default is `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign` (validated). Only deviate if:

- The user said "voice cloning" or "clone my voice" → `Qwen3-TTS-12Hz-1.7B-Base`
  (or `0.6B-Base` for cheaper).
- The user said "fixed premium speakers" / "consistent voice across sessions"
  → `Qwen3-TTS-12Hz-1.7B-CustomVoice`.
- The user said "small / fast / cheap" → `Qwen3-TTS-12Hz-0.6B-CustomVoice`.

If unsure: stick with the default. See [docs/MODELS.md](docs/MODELS.md).

### 2. Standalone or paired with vLLM main + ASR?

- **Standalone** (just synthesis): run `bash deploy/deploy-tts.sh` or
  `docker compose up -d`. Done.
- **Paired with vLLM main + ASR** (full voice agent stack): bring up the
  others FIRST (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)), then
  run this one. Shared bridge is `aeon-stack` —
  `docker network create aeon-stack` once.

## Bring-up — non-interactive

```bash
git clone https://github.com/AEON-7/qwen3-tts-server
cd qwen3-tts-server

# default (validated 1.7B-VoiceDesign)
docker network create aeon-stack 2>/dev/null || true
docker compose up -d
```

Or with the deploy script (interactive picker):

```bash
bash deploy/deploy-tts.sh
```

## Verification — wait for ready

The model loads on container start; ready in ~10–20 s on first boot.

```bash
until curl -sf -m 2 http://localhost:8002/health 2>/dev/null | grep -q model_loaded; do sleep 2; done
echo "TTS ready"
```

If polling exceeds 2 min, check logs:

```bash
docker logs --tail 50 qwen3-tts | grep -E '\[load\]|ERROR|Traceback'
```

The container should print three `[load]` lines on success, ending with
`[load] supported_languages=[...]`.

### Common boot failures and recovery

**`OOM` / `out of memory`**

If a 27B+ vLLM main is co-resident on the same Spark and consuming
near-cap GPU memory, the TTS load may not have room for its ~4 GB. Bring
the LLM main down to `--gpu-memory-utilization 0.70` (or lower the TTS
to a 0.6B variant: `QWEN_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice
bash deploy/deploy-tts.sh`).

**`flash-attn install failed; will fall back to sdpa at runtime`** (build-time)

This is non-fatal (legacy v0.1 image only — the v0.3.0 build uses the
faster-qwen3-tts engine, not flash-attn). The image still boots; TTS
will use SDPA attention instead. RTF drops from ~1.30× to ~0.7×, still
usable. To get flash-attn back: rebuild from this repo's Dockerfile with
the right `FLASH_ATTN_CUDA_ARCHS` for your GPU.

## Smoke test

```bash
# 1. synthesize
curl -sf -X POST http://localhost:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"input":"Hello world","response_format":"wav"}' \
  --output /tmp/agent_smoke.wav
[[ -s /tmp/agent_smoke.wav ]] \
  && echo "TTS ok ($(stat -c%s /tmp/agent_smoke.wav) bytes)" \
  || { echo "TTS FAIL"; exit 1; }

# 2. check it's actually a WAV (RIFF magic)
head -c 4 /tmp/agent_smoke.wav | grep -q RIFF \
  && echo "WAV format ok" \
  || { echo "TTS FAIL — not a valid WAV"; exit 1; }
```

If both pass, the stack is operational. For an end-to-end voice round-trip
test (text → TTS → ASR → text), also bring up `qwen3-asr-server` and run
the round-trip probe in [docs/INTEGRATIONS.md → "Custom client"](docs/INTEGRATIONS.md#5-custom-client--raw-http).

## Common follow-up tasks

### Wire matrix-voip-agent on a separate host

See [docs/INTEGRATIONS.md → "Matrix voice calls"](docs/INTEGRATIONS.md#1-matrix-voice-calls-recommended-for-ai-on-matrix).
Don't put hardcoded IPs in checked-in code — use `SPARK_HOST` as the
substitution variable.

### Pair with the Qwen3.6-27B AEON Ultimate vLLM main + qwen3-asr-server

Run the docker commands in
[docs/ARCHITECTURE.md → "The three sidecars"](docs/ARCHITECTURE.md#the-three-sidecars).
Order matters only if memory is tight (bring up the heavy LLM first).

### Switch model variants live (legacy v0.1 image)

```bash
docker rm -f qwen3-tts
QWEN_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice bash deploy/deploy-tts.sh
```

The HF cache is bind-mounted, so a previously-downloaded variant restarts
instantly. (On the v0.3.0 streaming build no switch is needed for voice
cloning — VoiceDesign and Base are both loaded; select per request with
`model: qwen3-tts` / `model: qwen3-tts-clone`.)

## Tear-down

```bash
docker rm -f qwen3-tts
docker network rm aeon-stack 2>/dev/null || true
# HF cache at ${HOME}/.cache/huggingface is preserved.
```

## Don'ts

- Don't bind `8002` to a public interface without putting an auth proxy in
  front. Clients send `Authorization: Bearer <YOUR_API_KEY>` by
  convention, but the key is operator-configured and enforcement depends
  on the deployment — treat the port as unauthenticated unless verified.
- Don't `pip install vllm[audio]` into a derivative image — the meta-package
  re-resolves and downgrades vLLM core deps which silently regresses TTS
  hot inference latency by ~5×. The Dockerfile installs only `av --no-deps`;
  soundfile is already pulled in by qwen-tts.
- Don't use `--no-verify` on git operations against this repo unless
  explicitly asked.

## Output convention for autonomous reports

If you're an agent reporting back to a parent:

```
qwen3-tts-server bring-up: OK
- model: <model-id>
- port: 8002
- bridge: aeon-stack ready
- smoke test: <wall ms> for "Hello world" → <bytes> WAV
- paired with: <none | qwen3-asr-server | full stack>
```

If FAIL, include the failing health-check output and the last 20 lines of
the container's logs.
