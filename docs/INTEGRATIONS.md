# Integration Guides

How to wire `qwen3-tts-server` into popular voice / agent stacks. Each
section is self-contained: copy-pasteable config, no read-the-other-doc
required.

The convention used throughout: replace `${SPARK_HOST}` (or `${TTS_HOST}`)
with the host address where this image is running. Don't hardcode IPs in
checked-in code — keep them as env-var substitutions.

---

## 1. Matrix voice calls (recommended for AI-on-Matrix)

The fastest path to "I can dial my AI in a Matrix call" is to pair this
image with [**matrix-voip-agent**](https://github.com/AEON-7/matrix-voip-agent)
— a headless WebRTC bridge that auto-answers Matrix VoIP calls and pipes
audio between the call and your AI sidecars via PipeWire.

Combine matrix-voip-agent with **any Matrix homeserver** (stock
[Synapse](https://github.com/element-hq/synapse) /
[Conduit](https://gitlab.com/famedly/conduit), or our customized setup with
direct calling features) and you have an AI that's reachable from any
Matrix client (Element, nheko, FluffyChat, etc.) by dialing a contact.

### matrix-voip-agent `.env`

These are the env names the agent actually reads — full table in the
[matrix-voip-agent README](https://github.com/AEON-7/matrix-voip-agent#configuration)
and [AGENTS.md](https://github.com/AEON-7/matrix-voip-agent/blob/main/AGENTS.md):

```bash
# disable the old whisper.cpp + ElevenLabs paths
WHISPER_ENABLED=false
# ELEVENLABS_API_KEY=        # leave unset

# pair with qwen3-asr-server for the speech recognition leg
OMNI_ASR_ENABLED=true
OMNI_ASR_BASE_URL=http://${SPARK_HOST}:8001/v1
OMNI_ASR_MODEL=qwen3-asr

# wire to qwen3-tts-server (this repo)
VOXTRAL_ENABLED=true
VOXTRAL_BASE_URL=http://${SPARK_HOST}:8002/v1
VOXTRAL_MODEL=qwen3-tts              # qwen3-tts-clone for clone mode
VOXTRAL_VOICE_DESCRIPTION="A warm, expressive adult voice with natural cadence."
VOXTRAL_STREAMING=true               # recommended: first audio ~0.4 s
VOXTRAL_API_KEY=<YOUR_API_KEY>
```

### Audio format on the wire

- **Streaming (recommended, v0.3.0):** `stream: true` +
  `response_format: "pcm"` yields raw **s16le mono 24 kHz** chunks as
  they are generated (chunked transfer-encoding; read the
  `x-audio-sample-rate` response header rather than hardcoding 24 kHz).
  matrix-voip-agent does exactly this when `VOXTRAL_STREAMING=true` and
  pipes the chunks straight into PipeWire — first audio ~0.4 s.
- **Non-streaming:** the server returns **WAV (24 kHz mono 16-bit PCM by
  default)**. matrix-voip-agent strips the RIFF header (`data` chunk
  offset) and pipes the raw PCM to `pw-play -r 24000 -f s16 -c 1`.
- If you're rolling your own bridge, that's the contract: POST JSON with
  `input` text, get back audio bytes (or a chunked stream). Read the
  sample rate from the `x-audio-sample-rate` header or the WAV header
  (offset 24, little-endian uint32) — don't hardcode 24 kHz on the
  client side, future model variants may differ.

---

## 2. OpenAI SDK (Python / TS / anywhere)

This server speaks OpenAI's `/v1/audio/speech`. Drop in any OpenAI SDK
and point `base_url` at it:

### Python

```python
from openai import OpenAI

client = OpenAI(base_url=f"http://{SPARK_HOST}:8002/v1", api_key="<YOUR_API_KEY>")

resp = client.audio.speech.create(
    model="qwen3-tts",
    input="The quick brown fox jumps over the lazy dog.",
    voice="A warm, expressive adult voice.",
    response_format="wav",
)
resp.stream_to_file("speech.wav")
```

### TypeScript

```typescript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: `http://${SPARK_HOST}:8002/v1`,
  apiKey: "<YOUR_API_KEY>",
});

const resp = await client.audio.speech.create({
  model: "qwen3-tts",
  input: "Hello world",
  voice: "A friendly assistant voice.",
  response_format: "wav",
});
const buf = Buffer.from(await resp.arrayBuffer());
fs.writeFileSync("speech.wav", buf);
```

---

## 3. OpenWebUI

OpenWebUI's Audio settings expect an OpenAI-compatible TTS endpoint:

```
Settings → Audio → Text-to-Speech Engine: OpenAI
  TTS API Base URL: http://${SPARK_HOST}:8002/v1
  TTS API Key:      <YOUR_API_KEY>
  TTS Model:        qwen3-tts
  TTS Voice:        A warm, expressive adult voice.
```

The "voice" field is sent as the OpenAI `voice` param, which this server
treats as the VoiceDesign description — so any natural-language voice
description works. (Set TTS Model to `qwen3-tts-clone` and Voice to a
cloned-voice id from `GET /v1/audio/voices` for clone mode.)

---

## 4. Home Assistant (`openai_conversation` integration)

Two paths:

### Via the [`openai_conversation` integration's TTS mode](https://www.home-assistant.io/integrations/openai_conversation/)

```yaml
# configuration.yaml
openai_conversation:
  - name: "Local TTS"
    url: !secret tts_url           # http://${SPARK_HOST}:8002/v1
    api_key: !secret tts_api_key   # any non-empty string
    tts_model: qwen3-tts
    tts_voice: "A friendly assistant voice."
```

### Via an Assist pipeline pointing at the same endpoint

In Settings → Voice Assistants → your pipeline → TTS, choose your
"OpenAI-compatible" provider and point it at the same URL. Pair with the
companion `qwen3-asr-server` for end-to-end Assist voice.

---

## 5. Custom client — raw HTTP

Dead simple, no SDK needed:

```bash
curl -sf -X POST http://${SPARK_HOST}:8002/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{
    "input": "Hello world.",
    "voice": "A neutral assistant voice.",
    "response_format": "wav"
  }' \
  --output speech.wav
```

Request body fields (v0.3.0 — full reference with sampling knobs and
aliases in the [README API reference](../README.md#api-reference-v030-from-the-live-openapi)):

| field             | required | notes                                                      |
| ----------------- | :------: | ---------------------------------------------------------- |
| `input`           |    ✓     | Text to synthesize.                                        |
| `model`           |          | `qwen3-tts` (default, VoiceDesign) or `qwen3-tts-clone` (voice clone). |
| `mode`            |          | `voice_design` \| `voice_clone` — alternative to picking via `model`. |
| `voice`           |          | Free-form voice description, or a cloned-voice id from `GET /v1/audio/voices` (clone mode). |
| `instructions`    |          | VoiceDesign instruction text (aliases `instruct`, `prompt`). |
| `ref_audio` / `ref_text` |   | Clone reference sample + transcript.                       |
| `response_format` |          | `wav` (default), `flac`, `mp3`, or `pcm` (raw s16le — recommended for streaming). |
| `stream`          |          | `true` to stream chunks as they are generated.             |
| `chunk_size`      |          | Streaming codec frames per audio chunk.                    |
| `language`        |          | Full language name: `English`, `Chinese`, `Auto`, ... Auto-detect if omitted. |
| `speed`           |          | Accepted for OpenAI compatibility; **currently ignored**.  |
| sampling knobs    |          | `max_new_tokens` (1–8192, def 2048), `min_new_tokens`, `temperature` (def 0.9), `top_k` (def 50), `top_p` (def 1.0), `repetition_penalty` (def 1.05). |

Auth: clients send `Authorization: Bearer <YOUR_API_KEY>` — the key is
operator-configured on the deployment, and enforcement depends on it.
Put an auth proxy in front for any non-trusted network; never expose
port 8002 publicly.

---

## 6. Other LLM-orchestrated agents (LangChain, LlamaIndex, custom)

Anything that consumes an OpenAI TTS-compatible base URL works unchanged.
The deciding fact is the `/v1/audio/speech` shape, not the underlying
engine. If your framework's TTS abstraction lets you set a custom
`base_url` + `api_key`, it'll work here.

---

## A note on running this image elsewhere

This applies to the **legacy v0.1 image** in this repo
(`ghcr.io/aeon-7/qwen3-tts-server:latest`): nothing in it is
Spark-specific *except* the flash-attn 2 wheel, which is built for
`sm_120`. On other Blackwell / consumer / datacenter GPUs the image will
boot — flash-attn auto-falls back to SDPA at runtime if the kernel can't
load. Re-build with the right `FLASH_ATTN_CUDA_ARCHS` if you want native
flash-attn there too.

The **v0.3.0 streaming build** runs on the
[faster-qwen3-tts](https://github.com/andimarafioti/faster-qwen3-tts)
CUDA-graph engine instead; for portability of that path see the engine
repo and the DGX Spark packaging at
[mARTin-B78/dgx-spark-faster-qwen3-tts](https://github.com/mARTin-B78/dgx-spark-faster-qwen3-tts).
