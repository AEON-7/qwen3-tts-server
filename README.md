# qwen3-tts-server

OpenAI-compatible `/v1/audio/speech` HTTP server backed by
[**Qwen3-TTS-12Hz-1.7B-VoiceDesign**](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign),
optimized for **NVIDIA DGX Spark** (GB10, sm_121a / sm_120 wheels) and
other Blackwell consumer GPUs.

A thin FastAPI wrapper (`server.py`) around the `qwen-tts` Python SDK that:

- Loads the model on **CUDA** in **bf16** with **flash-attn 2** (auto-falls back to SDPA / eager).
- Exposes the OpenAI `/v1/audio/speech` body (`input`, `voice`, `response_format`) plus an
  optional `language` hint, so existing OpenAI SDK clients work unchanged.
- Maps OpenAI `voice` → qwen-tts `instruct` (free-form natural-language voice description —
  e.g. *"A warm, gravelly male voice with a slight Scottish accent, slow pacing."*).
- Returns `wav` / `flac` / `mp3` (mp3 needs system `libmp3lame`).

Designed to drop into a multi-container voice pipeline behind a vLLM main model
on the same Docker bridge — keep the LLM → TTS hop on loopback, push only the
audio bytes to the client.

## Performance — DGX Spark (GB10, sm_121a)

End-to-end probe: vLLM main (Qwen3.6-27B NVFP4 + DFlash) → `/v1/chat/completions`
→ this TTS server → 16-bit / 24 kHz WAV. Both containers on the same Docker
bridge.

| stage         | cold       | hot         |
| ------------- | ---------- | ----------- |
| LLM (8 toks)  | 1460 ms    | 482 ms      |
| TTS synth     | 5140 ms    | **2137 ms** |
| TTS RTF       | 0.39x      | **1.16x**   |
| TOTAL wall    | 6600 ms    | **2619 ms** |

(31 input chars → ~2.5 s playback; "REAL-TIME" = TTS faster than playback rate.)

For reference, the same server on **CPU / fp32** synthesized the same clip in
**~47 s** (RTF 0.05x). The CUDA + bf16 + flash-attn 2 path is ~23× faster.

## Quickstart

### Docker Compose (recommended)

```bash
# one-time: create the shared bridge if it doesn't exist
docker network create aeon-stack

# build (first time compiles flash-attn for sm_120 — slow, ~10–15 min on Spark)
# subsequent restarts use the cached image
docker compose up -d --build

# verify
curl http://localhost:8002/health
# {"status":"ok","model_loaded":true}
```

### Synthesize speech

OpenAI-compatible — drop in the OpenAI SDK with `base_url=http://localhost:8002/v1`:

```bash
curl -X POST http://localhost:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "input": "The quick brown fox jumps over the lazy dog.",
    "voice": "A bright, expressive female voice with clear pronunciation and natural pacing.",
    "response_format": "wav"
  }' \
  --output speech.wav
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8002/v1", api_key="ignored")
resp = client.audio.speech.create(
    model="qwen3-tts",
    input="The quick brown fox jumps over the lazy dog.",
    voice="A bright, expressive female voice with clear pronunciation.",
    response_format="wav",
)
resp.stream_to_file("speech.wav")
```

## Voice design

`voice` is forwarded to qwen-tts as the `instruct` field — a free-form natural-language
description of the voice you want. The model conditions on this each call (no
voice cloning / reference audio). Examples:

- `"A neutral, friendly adult voice with clear pronunciation, moderate pace, and natural intonation."` (default)
- `"An elderly British man, gravelly and warm, slow and deliberate."`
- `"A cheerful young woman with a slight French accent, energetic pacing."`
- `"A robotic monotone, even cadence, no emotional inflection."`

## Configuration

All env vars are optional.

| var                       | default                                              | notes                                                       |
| ------------------------- | ---------------------------------------------------- | ----------------------------------------------------------- |
| `QWEN_TTS_MODEL`          | `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`               | HF repo id                                                  |
| `QWEN_TTS_TOKENIZER`      | `Qwen/Qwen3-TTS-Tokenizer-12Hz`                      | HF repo id                                                  |
| `QWEN_TTS_DEFAULT_VOICE`  | neutral adult description (see `server.py`)          | used when request omits `voice`                             |
| `QWEN_TTS_ATTN_IMPL`      | auto: `flash_attention_2` if available, else `sdpa`  | force one of `flash_attention_2` / `sdpa` / `eager`         |

The supported `language` values (auto-detected if omitted): `auto`, `chinese`,
`english`, `french`, `german`, `italian`, `japanese`, `korean`, `portuguese`,
`russian`, `spanish`. The OpenAI body field is short codes (`zh`, `en`, `ja`, ...)
which the server maps via the underlying SDK.

## Image

The Dockerfile starts from a vLLM image that already has the right
torch + audio stack for aarch64 / sm_121a:

```
FROM ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3
```

If you're not on Spark, swap the base image for any CUDA + torch image with
`librosa` / `soundfile` available, then rebuild. The flash-attn install line
auto-falls back to SDPA at runtime if the wheel build fails.

## Endpoints

- `GET  /health` — liveness + load status
- `GET  /v1/models` — single served model `qwen3-tts`
- `POST /v1/audio/speech` — OpenAI body, returns audio bytes

## License

Apache-2.0. Underlying model weights are released under the
[Qwen license](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign).
