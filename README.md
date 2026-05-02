# qwen3-tts-server

OpenAI-compatible voice-AI sidecars for **NVIDIA DGX Spark** (GB10, sm_121a /
sm_120 wheels) and other Blackwell consumer GPUs. One docker image, two
endpoints:

- **TTS** — `/v1/audio/speech` backed by [Qwen3-TTS-12Hz-1.7B-VoiceDesign](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign)
  via a thin FastAPI wrapper around the `qwen-tts` SDK. CUDA + bf16 +
  flash-attn 2 (sm_120 wheel built into the image).
- **ASR** — `/v1/audio/transcriptions` backed by [Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)
  served natively by vLLM (`Qwen3ASRForConditionalGeneration`).

Both endpoints follow OpenAI request shapes so existing OpenAI SDK clients
work unchanged.

## Performance — DGX Spark, hot path

| stage  | wall    | RTF    | notes                                      |
| ------ | ------- | ------ | ------------------------------------------ |
| TTS    | 1476 ms | 1.30×  | 31 chars → 1.92 s mono 24 kHz WAV          |
| ASR    | 120 ms  | 16.04× | 1.92 s WAV → text                          |
| **Total round-trip** | **1.6 s** | — | text → speech → text, exact match |

Plus the LLM main of your choice via the same Docker bridge (see
[Recommended full-stack pairing](#recommended-full-stack-pairing) below).

## QuickStart

The image is published at **`ghcr.io/aeon-7/qwen3-tts-server:latest`**.

### One-shot full sidecar stack

```bash
# clone for the deploy scripts (image itself comes from ghcr)
git clone https://github.com/AEON-7/qwen3-tts-server
cd qwen3-tts-server

bash deploy/deploy-stack.sh           # interactive: pick model variants
# or:
bash deploy/deploy-stack.sh --yes     # use validated defaults, non-interactive
```

This brings up:

- `qwen3-tts` on `:8002` — TTS sidecar
- `qwen3-asr` on `:8001` — ASR sidecar
- shared `aeon-stack` Docker bridge for sub-ms LLM↔ASR↔TTS hops

Then add your vLLM main on `:8000` joined to `aeon-stack` — see
[ARCHITECTURE.md](docs/ARCHITECTURE.md) for the recommended pairing.

### Just one sidecar

```bash
bash deploy/deploy-tts.sh             # interactive TTS only
bash deploy/deploy-asr.sh             # interactive ASR only
```

Both scripts let you pick from the [supported model variants](docs/MODELS.md);
defaults are the validated `1.7B-VoiceDesign` for TTS and `0.6B` for ASR.

### Smoke tests

```bash
# TTS — text in, WAV bytes out
curl -X POST http://localhost:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"input":"Hello world","response_format":"wav"}' \
  --output speech.wav

# ASR — WAV in, text out
curl -X POST http://localhost:8001/v1/audio/transcriptions \
  -F file=@speech.wav -F model=qwen3-asr -F language=en
```

If both return 200 you have a working voice loop.

## Environment variables

All configuration is via env. Below is the exhaustive list — every variable
is optional and has a sensible default.

### TTS sidecar

| var                        | default                                       | meaning                                                                       |
| -------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------- |
| `QWEN_TTS_MODEL`           | `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`        | HF repo id of the TTS model. See [MODELS.md](docs/MODELS.md).                 |
| `QWEN_TTS_TOKENIZER`       | `Qwen/Qwen3-TTS-Tokenizer-12Hz`               | HF repo id of the codec tokenizer (shared by every TTS variant).              |
| `QWEN_TTS_DEFAULT_VOICE`   | `"A neutral, friendly adult voice ..."`       | `instruct` description used when a request omits `voice`.                     |
| `QWEN_TTS_ATTN_IMPL`       | auto: `flash_attention_2` else `sdpa`         | force one of `flash_attention_2` / `sdpa` / `eager`.                          |

### ASR sidecar (passed to vLLM via deploy-asr.sh)

| var          | default                | meaning                                                              |
| ------------ | ---------------------- | -------------------------------------------------------------------- |
| `QWEN_ASR_MODEL` | `Qwen/Qwen3-ASR-0.6B`  | HF repo id of the ASR model.                                         |
| `GPU_MEM`    | `0.08`                 | vLLM `--gpu-memory-utilization`. Bump to `0.10+` for larger ASR.     |
| `MAX_LEN`    | `8192`                 | vLLM `--max-model-len`. ASR inputs rarely exceed 4 K tokens.         |
| `MAX_SEQS`   | `4`                    | vLLM `--max-num-seqs` (concurrent transcription jobs).               |

### Shared / deployment

| var          | default                                              | meaning                                                                  |
| ------------ | ---------------------------------------------------- | ------------------------------------------------------------------------ |
| `IMAGE`      | `ghcr.io/aeon-7/qwen3-tts-server:latest`             | Docker image to run.                                                     |
| `PORT`       | `8002` (TTS) / `8001` (ASR)                          | Host port to bind.                                                       |
| `NETWORK`    | `aeon-stack`                                         | Docker bridge name (auto-created if missing). Join your vLLM main here too. |
| `HF_CACHE`   | `${HOME}/.cache/huggingface`                         | Host path for the HF model cache, bind-mounted into the container.       |
| `HF_TOKEN`   | (unset)                                              | Forwarded to the container if set. Needed only for gated repos.          |
| `CONTAINER`  | `qwen3-tts` / `qwen3-asr`                            | Container name.                                                          |

### Client-side (matrix-voip-agent / OpenClaw)

When integrating from another host, point your client at the Spark IP. These
are NOT consumed by this server — they're the conventional names downstream
clients should use:

| var               | example                                           | meaning                                       |
| ----------------- | ------------------------------------------------- | --------------------------------------------- |
| `LLM_BASE_URL`    | `http://192.168.1.116:8000/v1`                    | vLLM main OpenAI base URL.                    |
| `LLM_MODEL`       | `qwen36-ultimate-xs`                              | served-model-name on the vLLM main.           |
| `TTS_ENDPOINT`    | `http://192.168.1.116:8002/v1/audio/speech`       | this server's TTS endpoint.                   |
| `TTS_MODEL`       | `qwen3-tts`                                       | OpenAI `model` field (single served model).   |
| `TTS_VOICE`       | (free-form description)                           | maps to qwen-tts `instruct`.                  |
| `ASR_ENDPOINT`    | `http://192.168.1.116:8001/v1/audio/transcriptions` | this server's ASR endpoint.                 |
| `ASR_MODEL`       | `qwen3-asr`                                       | OpenAI `model` field.                         |
| `ASR_LANGUAGE`    | `en` (or `auto`, `zh`, `ja`, ...)                 | ASR language hint.                            |

## Recommended full-stack pairing

This sidecar pair is designed to slot in next to a fast vLLM main on the same
Docker bridge. Recommended:

> **Qwen3.6-27B AEON Ultimate Uncensored MTP-XS** (NVFP4 + DFlash speculative
> decoding) served by the AEON-7 v3 vLLM image:
> [`ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3`](https://github.com/AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash)

That pairing fits comfortably alongside this image on a single Spark with
~95 GB unified RAM headroom and lands a **2.6 s end-to-end voice turn**
(text question → spoken answer ready). Full rationale + bring-up in
[ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Documentation index

- [docs/MODELS.md](docs/MODELS.md) — every supported Qwen3-TTS / Qwen3-ASR
  variant, params, when to pick each one.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — recommended deployment
  topology including vLLM main, Matrix server, OpenClaw gateway, and the
  matrix-voip-agent integration.
- [agents.md](agents.md) — agent-readable bring-up runbook for autonomous
  deployments.
- [Dockerfile](Dockerfile) — image definition, including the flash-attn 2
  sm_120 build and the `av` (PyAV) install for vLLM's audio decode fallback.
- [server.py](server.py) — the TTS FastAPI wrapper (~165 lines).

## Endpoints

- `GET  /health` — liveness + load status (TTS sidecar)
- `GET  /v1/models` — single served model
- `POST /v1/audio/speech` — OpenAI body, returns audio bytes (TTS)
- `POST /v1/audio/transcriptions` — OpenAI multipart/form-data, returns text (ASR; vLLM-native)

## License

Apache-2.0. Underlying model weights are released under their respective
[Qwen licenses](https://huggingface.co/Qwen).
