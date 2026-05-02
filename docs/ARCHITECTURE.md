# Recommended Deployment Architecture

This page describes the deployment topology this image is designed for: a
single low-latency voice-AI host that serves an LLM main, ASR, and TTS as
three OpenAI-compatible endpoints on a shared Docker bridge, with downstream
clients (Matrix server, OpenClaw, agents) speaking to it over the LAN.

## Topology

```
                      ┌──────────────────────── DGX Spark (192.168.1.116) ─────────────────────────┐
                      │                                                                             │
                      │   docker bridge "aeon-stack" (172.20.0.0/16)                                │
                      │   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐          │
                      │   │ qwen36-aeon-xs   │  │ qwen3-asr        │  │ qwen3-tts        │          │
                      │   │ vLLM main:8000   │  │ vLLM ASR:8001    │  │ FastAPI TTS:8002 │          │
                      │   │ Qwen3.6-27B      │  │ Qwen3-ASR-0.6B   │  │ Qwen3-TTS-1.7B   │          │
                      │   │ NVFP4 + DFlash   │  │ flash-attn 2     │  │ bf16+flash-attn 2│          │
                      │   └──────────┬───────┘  └─────────┬────────┘  └─────────┬────────┘          │
                      │              │                    │                     │                   │
                      │              └────────────────────┼─────────────────────┘                   │
                      │                                   │                                         │
                      └───────────────────────────────────┼─────────────────────────────────────────┘
                                                          │ host network (LAN, ~1 ms)
                                                          ▼
                      ┌──────────────────────── pacific (192.168.1.155) ────────────────────────────┐
                      │                                                                             │
                      │   matrix-voip-agent       OpenClaw gateway       Matrix homeserver          │
                      │   (Node/TS, headless)     (skills + memory)      (Synapse / Conduit)        │
                      │                                                                             │
                      └─────────────────────────────────────────────────────────────────────────────┘
```

## Why this layout

- **All three AI services on one Docker bridge.** Inter-container hops are
  loopback-fast (sub-ms). The LLM → TTS pipeline never leaves the host.
- **OpenClaw + Matrix on a separate host.** Voice agents only need a thin
  audio-bytes pipe from the Matrix WebRTC plane to the Spark sidecars, which
  is one LAN hop (~1-2 ms — negligible compared to the typical 30-200 ms an
  internet hop would add).
- **No co-location of orchestration with inference.** Keeps the Spark
  dedicated to GPU work; OpenClaw / Matrix can be independently restarted.

## Recommended LLM main

> **Qwen3.6-27B AEON Ultimate Uncensored MTP-XS**
> ([Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash](https://github.com/AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash))
>
> 27B params, NVFP4 hardware-quantized for Blackwell, hybrid Mamba-2 +
> attention layers, served with DFlash block-diffusion speculative decoding
> (k=15) for high token throughput on a single Spark. Pairs with this image's
> v3 base — same vLLM build, no patch divergence.

Bring-up command (compose / docker run, joined to `aeon-stack`):

```bash
docker run -d --name qwen36-aeon-xs \
  --runtime nvidia --network aeon-stack -p 8000:8000 \
  --shm-size=4gb --restart unless-stopped \
  -v ${HOME}/.cache/huggingface:/root/.cache/huggingface \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e ENABLE_NVFP4_SM100=0 \
  -e VLLM_NVFP4_GEMM_BACKEND=flashinfer-cutlass \
  -e VLLM_USE_FLASHINFER_MOE_FP4=0 \
  -e VLLM_USE_FLASHINFER_SAMPLER=1 \
  ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3 \
  vllm serve aeon-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-MTP-XS \
    --served-model-name qwen36-ultimate-xs \
    --host 0.0.0.0 --port 8000 \
    --gpu-memory-utilization 0.75 \
    --max-model-len 32768 \
    --enable-auto-tool-choice --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3 \
    --speculative-config '{"method":"dflash","model":"z-lab/Qwen3.6-27B-DFlash","num_speculative_tokens":15}' \
    --trust-remote-code
```

(See the [`vllm-aeon-ultimate-dflash` image docs](https://github.com/AEON-7/Qwen3.6-NVFP4-DFlash)
for the full env-var reference and quant-backend tradeoffs.)

## Memory budget on Spark (128 GB unified)

| service                                       | vLLM `gpu_mem_util` | resident   |
| --------------------------------------------- | ------------------- | ---------- |
| qwen36-aeon-xs (27B NVFP4 + DFlash, BF16 KV)  | 0.75                | ~96 GB     |
| qwen3-asr (0.6B)                              | 0.06–0.08           | ~5–10 GB   |
| qwen3-tts (1.7B, bf16, transformers)          | n/a                 | ~4 GB CUDA |
| host kernel + buffer cache + Docker overhead  | —                   | ~10 GB     |
| free / margin                                 | —                   | **~10 GB** |

That margin is tight; never push `gpu_memory_utilization` past **0.88** on
unified-memory Spark — see the
[`gpu-memory-utilization` cap note](https://github.com/AEON-7/Qwen3.6-NVFP4-DFlash#dgx-spark-gpu_memory-utilization-caps-at-088).

## Latency budget (measured, hot path)

| stage                                       | wall                |
| ------------------------------------------- | ------------------- |
| inbound RTP packet → matrix-voip-agent      | ~5 ms (Matrix WebRTC) |
| ASR (1.92 s clip → text)                    | 120 ms              |
| LLM (vLLM `chat/completions`, 8 tok answer) | 482 ms              |
| TTS (text → 1.92 s WAV)                     | 1476 ms             |
| outbound RTP packet → Matrix client         | ~5 ms                |
| **End-to-end voice turn**                   | **~2.1 s**          |

## Integration: matrix-voip-agent

The matrix-voip-agent (https://github.com/AEON-7/matrix-voip-agent) is a
headless WebRTC bridge that auto-answers Matrix VoIP calls and pipes audio
to/from a configurable AI backend.

To point it at this stack, set the following on the matrix-voip-agent host:

```bash
# .env on pacific (192.168.1.155)

# disable old paths
WHISPER_ENABLED=false
# ELEVENLABS_API_KEY=    # leave unset

# wire to Spark sidecars
STT_BACKEND=qwen
ASR_ENDPOINT=http://192.168.1.116:8001/v1/audio/transcriptions
ASR_MODEL=qwen3-asr
ASR_LANGUAGE=en

TTS_BACKEND=qwen
TTS_ENDPOINT=http://192.168.1.116:8002/v1/audio/speech
TTS_MODEL=qwen3-tts
TTS_VOICE="A warm, expressive adult voice with natural cadence."

# wire LLM main
LLM_BASE_URL=http://192.168.1.116:8000/v1
LLM_MODEL=qwen36-ultimate-xs
LLM_API_KEY=ignored        # any non-empty string works
```

Audio formats expected on the wire:

- ASR consumes WAV (any rate; vLLM resamples internally).
  matrix-voip-agent captures PCM s16le 16 kHz mono from `pw-record` and
  wraps it in a WAV header in-memory before POSTing.
- TTS produces WAV (24 kHz mono 16-bit by default) — strip the RIFF header
  and pipe the raw PCM to `pw-play -r 24000 -f s16 -c 1`.

## Integration: OpenClaw

If your OpenClaw gateway has its own LLM client config (rather than always
delegating to matrix-voip-agent), point it at the same vLLM main:

```bash
LLM_BASE_URL=http://192.168.1.116:8000/v1
LLM_MODEL=qwen36-ultimate-xs
LLM_API_KEY=ignored
```

OpenClaw doesn't currently call the ASR/TTS endpoints directly — those are
voice-pipeline concerns, owned by matrix-voip-agent in the recommended
topology. The voice loop carries OpenClaw's memory + skills context because
matrix-voip-agent forwards each turn through OpenClaw before hitting the
LLM main.

## IP-as-environment-variable convention

Everything LAN-facing should be configurable. Every example above uses a
literal `192.168.1.116` for clarity, but in production this should be an
env var your deploy tooling populates per-environment:

```bash
SPARK_HOST=192.168.1.116
LLM_BASE_URL=http://${SPARK_HOST}:8000/v1
ASR_ENDPOINT=http://${SPARK_HOST}:8001/v1/audio/transcriptions
TTS_ENDPOINT=http://${SPARK_HOST}:8002/v1/audio/speech
```

The image itself never assumes a host IP — it only listens on `0.0.0.0` and
joins the named Docker bridge. The IP-substitution lives in the client config
on pacific (matrix-voip-agent / OpenClaw `.env`).

## See also

- [README.md](../README.md) — top-level QuickStart.
- [docs/MODELS.md](MODELS.md) — supported model variants.
- [agents.md](../agents.md) — agent-readable bring-up runbook.
