# qwen3-tts-server

OpenAI-compatible `/v1/audio/speech` HTTP server backed by
[**Qwen3-TTS-12Hz-1.7B-VoiceDesign**](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign),
optimized for **NVIDIA DGX Spark** (GB10, sm_121a / sm_120 wheels) and
other Blackwell consumer GPUs.

A thin FastAPI wrapper around the `qwen-tts` Python SDK that:

- Loads the model on **CUDA** in **bf16** with **flash-attn 2** (auto-falls
  back to SDPA / eager if the kernel can't load).
- Exposes the OpenAI `/v1/audio/speech` body (`input`, `voice`,
  `response_format`) plus an optional `language` hint, so existing OpenAI
  SDK clients work unchanged.
- Maps OpenAI `voice` → qwen-tts `instruct` (free-form natural-language
  voice description, e.g. *"A warm, gravelly male voice with a slight
  Scottish accent, slow pacing."*).
- Returns `wav` / `flac` / `mp3` (mp3 needs system `libmp3lame`).
- **Real-time** on Spark (RTF 1.30× hot path).

For the matching ASR sidecar see
[**qwen3-asr-server**](https://github.com/AEON-7/qwen3-asr-server).

## Performance — DGX Spark, hot path

| stage         | wall    | RTF    |
| ------------- | ------- | ------ |
| TTS synthesis | 1480 ms | 1.30×  |

(input: 31 chars → 1.92 s mono 24 kHz WAV)

For reference, the same server on **CPU / fp32** synthesized the same clip
in ~47 s (RTF 0.05×). The CUDA + bf16 + flash-attn 2 path is **~32× faster**.

## QuickStart

The image is published at **`ghcr.io/aeon-7/qwen3-tts-server:latest`**.

### Docker Compose

```bash
docker network create aeon-stack         # one-time
git clone https://github.com/AEON-7/qwen3-tts-server
cd qwen3-tts-server
docker compose up -d

# verify
curl http://localhost:8002/health
# {"status":"ok","model_loaded":true}
```

### Or the deploy script (interactive variant picker)

```bash
bash deploy/deploy-tts.sh                # pick a Qwen3-TTS variant
# or non-interactive with the validated default:
QWEN_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign bash deploy/deploy-tts.sh
```

### Synthesize speech

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

### Or via the OpenAI SDK

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

`voice` is forwarded to qwen-tts as the `instruct` field — a free-form
natural-language description of the voice you want. The model conditions
on this each call (no voice cloning / reference audio in the
VoiceDesign variant). Examples:

- `"A neutral, friendly adult voice with clear pronunciation, moderate pace, and natural intonation."` (default)
- `"An elderly British man, gravelly and warm, slow and deliberate."`
- `"A cheerful young woman with a slight French accent, energetic pacing."`
- `"A robotic monotone, even cadence, no emotional inflection."`

For voice cloning from a 3-second reference audio, switch to
`Qwen3-TTS-12Hz-1.7B-Base` (or 0.6B-Base for cheaper). For a fixed catalog
of premium speakers, use `1.7B-CustomVoice`. See
[docs/MODELS.md](docs/MODELS.md).

## Recommended pairing — full voice-AI stack

Designed to slot in next to two other sidecars on the same Docker bridge,
making a complete LLM + ASR + TTS stack on a single host:

| sidecar             | repo                                                                                                       | purpose             |
| ------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------- |
| LLM main            | [aeon-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash](https://github.com/AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash) | reasoning / chat    |
| ASR                 | [aeon-7/qwen3-asr-server](https://github.com/AEON-7/qwen3-asr-server)                                      | speech → text       |
| **TTS** (this repo) | `ghcr.io/aeon-7/qwen3-tts-server:latest`                                                                   | text → speech       |

Hot end-to-end voice turn (text → speech → text, both directions): **~1.6 s**
on Spark. With the LLM in the middle for a real reasoning round-trip:
**~2.6 s**. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Wire it into a Matrix voice agent

The fastest path to "I can talk to my AI in a Matrix call":

```
+-------------+   WebRTC    +--------------------+   HTTP    +------------+
| Matrix      | <---------> | matrix-voip-agent  | --------> | qwen3-tts  |
| homeserver  |             | (PipeWire bridge)  |           | (this)     |
+-------------+             |                    |           +------------+
                            |                    |     HTTP  +------------+
                            |                    | --------> | LLM main   |
                            |                    |           +------------+
                            |                    |     HTTP  +------------+
                            |                    | --------> | qwen3-asr  |
                            +--------------------+           +------------+
```

Pair this server with [**matrix-voip-agent**](https://github.com/AEON-7/matrix-voip-agent)
— a headless WebRTC bridge that auto-answers Matrix VoIP calls and pipes
audio to/from the AI sidecars. Combined with any Matrix homeserver
(stock Synapse / Conduit, or our customized matrix-voip-agent setup with
direct calling features), you get an AI you can dial directly from your
Matrix client.

QuickStart on the matrix-voip-agent host:

```bash
# .env
TTS_BACKEND=qwen
TTS_ENDPOINT=http://${SPARK_HOST}:8002/v1/audio/speech
TTS_MODEL=qwen3-tts
TTS_VOICE="A warm, expressive adult voice with natural cadence."
```

Full integration walkthrough — including PCM↔WAV adapter wiring, audio
format constraints, ASR pairing — is in
[docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## Environment variables

All optional. Sensible defaults baked into the image.

### Server-side (read by `server.py`)

| var                       | default                                              | meaning                                                       |
| ------------------------- | ---------------------------------------------------- | ------------------------------------------------------------- |
| `QWEN_TTS_MODEL`          | `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`               | HF repo id of the TTS model. See [docs/MODELS.md](docs/MODELS.md). |
| `QWEN_TTS_TOKENIZER`      | `Qwen/Qwen3-TTS-Tokenizer-12Hz`                      | HF repo id of the codec tokenizer (shared by all variants).   |
| `QWEN_TTS_DEFAULT_VOICE`  | `"A neutral, friendly adult voice ..."`              | `instruct` description used when a request omits `voice`.     |
| `QWEN_TTS_ATTN_IMPL`      | auto: `flash_attention_2` else `sdpa`                | force one of `flash_attention_2` / `sdpa` / `eager`.          |

### Container env (deploy-side)

| var          | default                                              | meaning                                                            |
| ------------ | ---------------------------------------------------- | ------------------------------------------------------------------ |
| `IMAGE`      | `ghcr.io/aeon-7/qwen3-tts-server:latest`             | Image to pull.                                                     |
| `PORT`       | `8002`                                               | Host port to bind.                                                 |
| `NETWORK`    | `aeon-stack`                                         | Docker bridge (auto-created). Join your other sidecars here.       |
| `HF_CACHE`   | `${HOME}/.cache/huggingface`                         | Bind-mounted into the container.                                   |
| `HF_TOKEN`   | (unset)                                              | Forwarded if set. Needed only for gated HF repos.                  |
| `CONTAINER`  | `qwen3-tts`                                          | Container name.                                                    |

### Client-side (set on the host calling this server)

These names aren't read by this server — they're the convention any
downstream client (matrix-voip-agent, OpenClaw, your own scripts) should use:

| var               | example                                                   |
| ----------------- | --------------------------------------------------------- |
| `SPARK_HOST`      | `192.168.1.116`                                           |
| `TTS_ENDPOINT`    | `http://${SPARK_HOST}:8002/v1/audio/speech`               |
| `TTS_MODEL`       | `qwen3-tts`                                               |
| `TTS_VOICE`       | (free-form description)                                   |

## Documentation index

- [docs/MODELS.md](docs/MODELS.md) — Qwen3-TTS variants and when to pick each
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — recommended full-stack
  topology with vLLM main, qwen3-asr-server, Matrix, OpenClaw
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — wiring guides for Matrix
  voice calls, OpenAI SDK, OpenWebUI, Home Assistant, custom clients
- [agents.md](agents.md) — agent-readable bring-up runbook

## Endpoints

- `GET  /health` — liveness + load status
- `GET  /v1/models` — single served model `qwen3-tts`
- `POST /v1/audio/speech` — OpenAI body, returns audio bytes

## License

Apache-2.0. Underlying model weights are released under the
[Qwen license](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign).
