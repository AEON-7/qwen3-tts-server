# qwen3-tts-server

OpenAI-compatible `/v1/audio/speech` server for
[**Qwen3-TTS-12Hz-1.7B**](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign)
with **realtime chunked streaming**: audio is sent while the GPU is still
generating. Runs on the
[**faster-qwen3-tts**](https://github.com/andimarafioti/faster-qwen3-tts)
CUDA-graph engine, on **NVIDIA DGX Spark** (GB10 / Blackwell).

Two modes, served side-by-side:

- **VoiceDesign** (`model: qwen3-tts`) — describe the voice you want in
  free-form natural language, per request.
- **VoiceClone** (`model: qwen3-tts-clone`) — zero-shot clone from a
  ~3-second reference sample, or pick a pre-cloned voice from the
  server's `GET /v1/audio/voices` library.

Measured on DGX Spark (v0.3.0, streaming): **first audio in ~0.4 s**,
then ~2 s of audio delivered per ~1.16 s of wall time (**~1.65–1.75×
realtime**) — playback starts almost immediately instead of waiting
~12.7 s for a 22 s reply to fully synthesize.

For the matching ASR sidecar see
[**qwen3-asr-server**](https://github.com/AEON-7/qwen3-asr-server).

> ## ⚠️ Versions — read this first
>
> - **This repo's code (`server.py`, `Dockerfile`, and the
>   `ghcr.io/aeon-7/qwen3-tts-server:latest` image) is the original
>   v0.1.0 build**: a non-streaming FastAPI wrapper around the
>   `qwen-tts` SDK (bf16 + flash-attn 2), VoiceDesign only. It works,
>   but it does **not** stream, clone voices, or expose
>   `/v1/audio/voices`. Its instructions are kept below under
>   [Legacy v0.1 build](#legacy-v01-build-non-streaming-qwen-tts-sdk).
> - **The API documented in this README is the author's deployed v0.3.0
>   build** (`Qwen3-TTS VoiceDesign + VoiceClone Server`), the same
>   `server.py` evolved onto the **faster-qwen3-tts** streaming engine.
>   Everything below is verified against the live server's
>   `/openapi.json` and measured behavior. **Publishing the v0.3.0
>   source to this repo is pending.**
> - The same capability is available today from upstream: the
>   [**faster-qwen3-tts**](https://github.com/andimarafioti/faster-qwen3-tts)
>   engine (stock Qwen weights, CUDA-graph streaming) and its DGX Spark
>   packaging
>   [**mARTin-B78/dgx-spark-faster-qwen3-tts**](https://github.com/mARTin-B78/dgx-spark-faster-qwen3-tts)
>   (Docker image `martinb78/faster-qwen3-tts-dgx-spark:latest-streaming`,
>   voice library mounted at `/voices` — this matches the deployed
>   server's `/health`).

## Performance — measured (v0.3.0 streaming, DGX Spark)

| metric                                   | measured                      |
| ---------------------------------------- | ----------------------------- |
| Time to first audio chunk (streaming)    | **~0.4 s**                    |
| Sustained generation rate                | ~2 s audio per ~1.16 s wall (**~1.65–1.75× realtime**) |
| Non-streaming (full synthesis), 22 s reply | ~12.7 s wait before first byte |
| Voice-agent starts speaking (matrix-voip-agent, `VOXTRAL_STREAMING=true`) | ~1.0 s into the turn |

Wire format while streaming: chunked transfer-encoding; raw PCM is
**s16le mono 24 kHz** (read the `x-audio-sample-rate` response header
rather than hardcoding it).

## API reference (v0.3.0, from the live OpenAPI)

Title: `Qwen3-TTS VoiceDesign + VoiceClone Server`, version `0.3.0`.

### Endpoints

| endpoint                 | what it does                                                       |
| ------------------------ | ------------------------------------------------------------------ |
| `GET /health`            | liveness + backend/model/clone state (see below)                   |
| `GET /v1/models`         | **two** served models: `qwen3-tts` (VoiceDesign) and `qwen3-tts-clone` (1.7B-Base voice clone) |
| `GET /v1/audio/voices`   | the pre-cloned voice library (operator-managed, mounted at `/voices`) |
| `POST /v1/audio/speech`  | OpenAI body + Qwen3 extensions; returns audio bytes or a chunked stream |

### `GET /health`

```json
{
  "status": "ok",
  "model_loaded": true,
  "voice_design_model": "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
  "backend": "faster-qwen3-tts",
  "clone_loaded": true,
  "clone_model": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
  "clone_backend": "faster-qwen3-tts",
  "voice_library": "/voices",
  "sample_rate": 24000
}
```

**Verification tip:** `curl http://<host>:8002/health` must show
`"backend": "faster-qwen3-tts"` — if it doesn't, you're talking to the
legacy v0.1 build (its health is just `{"status":"ok","model_loaded":true}`).

### `GET /v1/audio/voices`

Lists the pre-cloned voices (currently 11 on the reference deployment:
`dali`, `dekker`, `einstein`, `hemingway`, `jobs`, `mcafee`, `mckenna`,
`musk`, `neville`, `tesla`, `watts`). Each entry:

```json
{"id": "einstein", "audio": "/voices/einstein.wav", "has_ref_text": true, "ref_text": "/voices/einstein.txt"}
```

Use an `id` as the `voice` field with `model: qwen3-tts-clone` to speak
in that voice without re-uploading reference audio.

### `POST /v1/audio/speech` — request body (`SpeechRequest`)

Only `input` is required. Validation errors return `422`.

| field                | type / default       | notes                                                                 |
| -------------------- | -------------------- | --------------------------------------------------------------------- |
| `input`              | str, **required**    | Text to synthesize.                                                    |
| `model`              | str, `qwen3-tts`     | `qwen3-tts` (VoiceDesign) or `qwen3-tts-clone` (voice clone).          |
| `mode`               | str?                 | `voice_design` \| `voice_clone` (alternative to picking via `model`).  |
| `voice`              | str?                 | Voice description (VoiceDesign), or a cloned-voice id from `/v1/audio/voices` (clone mode). |
| `instructions`       | str?                 | VoiceDesign instruction text. Aliases: `instruct`, `prompt`.           |
| `ref_audio`          | str?                 | Clone reference audio path or data URL. Aliases: `ref_audio_path`, `reference_audio`, `reference_audio_url`. |
| `ref_text`           | str?                 | Transcript of the reference audio. Alias: `reference_text`.            |
| `xvec_only`          | bool?                | Use speaker embedding only for cloning.                                |
| `append_silence`     | bool?                | Append silence to the clone prompt.                                    |
| `parity_mode`        | bool, `false`        | Forwarded to faster-qwen3-tts clone generation.                         |
| `response_format`    | str, `wav`           | `wav` \| `flac` \| `mp3` \| `pcm` (pcm = raw s16le mono 24 kHz — the recommended streaming format). |
| `language`           | str?                 | Language hint as a **full name**: `English`, `Chinese`, `Auto`, … (the legacy short codes `zh`/`en`/… are a v0.1-ism). |
| `stream`             | bool, `false`        | Stream PCM/WAV chunks as they are generated.                            |
| `chunk_size`         | int?                 | Streaming codec frames per audio chunk.                                 |
| `non_streaming_mode` | bool?                | Forwarded to Qwen3 generation.                                          |
| `speed`              | float, `1.0`         | **Accepted for OpenAI compatibility; currently ignored.**               |
| `max_new_tokens`     | int 1–8192, `2048`   | Sampling knob.                                                          |
| `min_new_tokens`     | int 0–256, `2`       | Sampling knob.                                                          |
| `temperature`        | float 0–2, `0.9`     | Sampling knob.                                                          |
| `top_k`              | int 0–1000, `50`     | Sampling knob.                                                          |
| `top_p`              | float 0–1, `1.0`     | Sampling knob.                                                          |
| `repetition_penalty` | float 0.1–5, `1.05`  | Sampling knob.                                                          |

### Response headers

| header                | value                                              |
| --------------------- | -------------------------------------------------- |
| `content-type`        | `audio/wav` (or per `response_format`)             |
| `transfer-encoding`   | `chunked` when streaming                           |
| `x-audio-sample-rate` | `24000` — read this instead of hardcoding          |
| `x-qwen-tts-mode`     | echo of the resolved mode, e.g. `voice_design`     |

### Authentication

Clients send a bearer token:

```
Authorization: Bearer <YOUR_API_KEY>
```

The key is **operator-configured** on the deployment (e.g.
matrix-voip-agent passes it via `VOXTRAL_API_KEY`). Note that
enforcement depends on the deployment — **never bind port 8002 to a
public interface without an auth proxy in front.**

## Streaming

Set `"stream": true`. The server starts sending audio chunks while the
GPU is still generating (first chunk ~0.4 s). With
`"response_format": "pcm"` the chunks are raw s16le mono 24 kHz —
pipeable straight into playback.

### curl (note `-N` to disable buffering)

```bash
curl -N -X POST http://<host>:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <YOUR_API_KEY>' \
  -d '{
    "input": "Streaming means playback starts before generation finishes.",
    "voice": "A bright, expressive female voice with natural pacing.",
    "response_format": "pcm",
    "stream": true
  }' | pw-play --rate 24000 --format s16 --channels 1 -
```

(`aplay -r 24000 -f S16_LE -c 1` works equally well.)

### Python (chunked read)

```python
import requests

with requests.post(
    "http://<host>:8002/v1/audio/speech",
    headers={"Authorization": "Bearer <YOUR_API_KEY>"},
    json={
        "input": "Streaming means playback starts before generation finishes.",
        "voice": "A bright, expressive female voice with natural pacing.",
        "response_format": "pcm",
        "stream": True,
    },
    stream=True,
) as r:
    r.raise_for_status()
    rate = int(r.headers.get("x-audio-sample-rate", 24000))
    for chunk in r.iter_content(chunk_size=4096):
        play(chunk, rate)  # feed your audio sink as chunks arrive
```

## Voice design

With `model: qwen3-tts` (default), `voice` / `instructions` is a
free-form natural-language description of the voice you want, applied
per request:

- `"A neutral, friendly adult voice with clear pronunciation, moderate pace, and natural intonation."`
- `"An elderly British man, gravelly and warm, slow and deliberate."`
- `"A cheerful young woman with a slight French accent, energetic pacing."`
- `"A robotic monotone, even cadence, no emotional inflection."`

## Voice clone

v0.3.0 loads **VoiceDesign and Base simultaneously** — no redeploy
needed to clone. Either:

```bash
# 1. zero-shot clone from a reference sample
curl -X POST http://<host>:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <YOUR_API_KEY>' \
  -d '{
    "model": "qwen3-tts-clone",
    "input": "This sentence is spoken in the cloned voice.",
    "ref_audio": "/voices/einstein.wav",
    "ref_text": "Transcript of the reference sample."
  }' --output clone.wav

# 2. or pick a pre-cloned voice from the library
curl -X POST http://<host>:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <YOUR_API_KEY>' \
  -d '{"model":"qwen3-tts-clone","input":"Hello from the library.","voice":"einstein"}' \
  --output clone.wav
```

Extra clone knobs: `xvec_only`, `append_silence`, `parity_mode` (see
the request table above).

## OpenAI SDK

```python
from openai import OpenAI
client = OpenAI(base_url="http://<host>:8002/v1", api_key="<YOUR_API_KEY>")
resp = client.audio.speech.create(
    model="qwen3-tts",
    input="The quick brown fox jumps over the lazy dog.",
    voice="A bright, expressive female voice with clear pronunciation.",
    response_format="wav",
)
resp.stream_to_file("speech.wav")
```

## Wire it into a Matrix voice agent

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

Pair this server with
[**matrix-voip-agent**](https://github.com/AEON-7/matrix-voip-agent) — a
headless WebRTC bridge that auto-answers Matrix VoIP calls and pipes
audio to/from the AI sidecars. With streaming enabled the agent starts
speaking ~1.0 s into the turn.

QuickStart on the matrix-voip-agent host (these are the env names the
agent actually reads — see its
[README env table](https://github.com/AEON-7/matrix-voip-agent#configuration)
and [AGENTS.md](https://github.com/AEON-7/matrix-voip-agent/blob/main/AGENTS.md)):

```bash
# .env
VOXTRAL_ENABLED=true
VOXTRAL_BASE_URL=http://${SPARK_HOST}:8002/v1
VOXTRAL_MODEL=qwen3-tts            # qwen3-tts-clone for clone mode
VOXTRAL_VOICE_DESCRIPTION="A warm, expressive adult voice with natural cadence."
VOXTRAL_STREAMING=true             # recommended: first audio ~0.4 s
VOXTRAL_API_KEY=<YOUR_API_KEY>
```

Full integration walkthrough — streaming PCM wiring, audio format
constraints, ASR pairing — is in
[docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## Deploying the v0.3.0 streaming build

Until the v0.3.0 source lands in this repo, the deployed-equivalent
stack is the upstream packaging:

```bash
# DGX Spark packaging of the faster-qwen3-tts streaming engine
# (see github.com/mARTin-B78/dgx-spark-faster-qwen3-tts for full docs)
docker pull martinb78/faster-qwen3-tts-dgx-spark:latest-streaming
```

Mount your voice library at `/voices` (each voice = `<id>.wav` +
`<id>.txt` transcript) to populate `GET /v1/audio/voices`. The engine
serves stock
[Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign)
and
[Qwen/Qwen3-TTS-12Hz-1.7B-Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base)
weights.

> Note: `ghcr.io/aeon-7/qwen3-tts-server:latest` (and `:v1.0.0`) is
> still the **v0.1.0 non-streaming build** (built 2026-05-02). It will
> be rebuilt when the v0.3.0 source is published here.

## Legacy v0.1 build (non-streaming, qwen-tts SDK)

<details>
<summary>The code currently in this repo. Click to expand.</summary>

A thin FastAPI wrapper around the `qwen-tts` Python SDK: loads
Qwen3-TTS-12Hz-1.7B-VoiceDesign on CUDA in bf16 with flash-attn 2
(auto-falls back to SDPA / eager), VoiceDesign only, full-synthesis
responses (no streaming, no clone mode, no `/v1/audio/voices`).
Measured on Spark: RTF ~1.30× hot path (1480 ms for a 1.92 s clip);
~32× faster than the same model on CPU/fp32.

### Docker Compose

```bash
docker network create aeon-stack         # one-time
git clone https://github.com/AEON-7/qwen3-tts-server
cd qwen3-tts-server
docker compose up -d

# verify (legacy health shape)
curl http://localhost:8002/health
# {"status":"ok","model_loaded":true}
```

### Or the deploy script (interactive variant picker)

```bash
bash deploy/deploy-tts.sh                # pick a Qwen3-TTS variant
# or non-interactive with the validated default:
QWEN_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign bash deploy/deploy-tts.sh
```

### Server-side env (read by the v0.1 `server.py` only)

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

</details>

## Recommended pairing — full voice-AI stack

Designed to slot in next to two other sidecars on the same Docker bridge,
making a complete LLM + ASR + TTS stack on a single host:

| sidecar             | repo                                                                                                       | purpose             |
| ------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------- |
| LLM main            | [aeon-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash](https://github.com/AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-DFlash) | reasoning / chat    |
| ASR                 | [aeon-7/qwen3-asr-server](https://github.com/AEON-7/qwen3-asr-server)                                      | speech → text       |
| **TTS** (this repo) | v0.3.0 streaming build (see [Deploying](#deploying-the-v030-streaming-build))                              | text → speech       |

With streaming TTS the voice agent starts speaking **~1.0 s** into a
turn; a fully-synthesized (non-streaming) end-to-end voice turn is
**~2.1 s** on Spark. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Credits

- [**andimarafioti/faster-qwen3-tts**](https://github.com/andimarafioti/faster-qwen3-tts)
  — the CUDA-graph streaming engine v0.3.0 runs on.
- [**mARTin-B78/dgx-spark-faster-qwen3-tts**](https://github.com/mARTin-B78/dgx-spark-faster-qwen3-tts)
  — DGX Spark Docker packaging of that engine
  (`martinb78/faster-qwen3-tts-dgx-spark:latest-streaming`).
- [**Qwen3-TTS**](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign)
  — stock model weights
  ([VoiceDesign](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign),
  [Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base)).

## Documentation index

- [docs/MODELS.md](docs/MODELS.md) — Qwen3-TTS variants and when to pick each
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — recommended full-stack
  topology with vLLM main, qwen3-asr-server, Matrix, OpenClaw
- [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md) — wiring guides for Matrix
  voice calls, OpenAI SDK, OpenWebUI, Home Assistant, custom clients
- [agents.md](agents.md) — agent-readable bring-up runbook

## License

Apache-2.0. Underlying model weights are released under the
[Qwen license](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign).
