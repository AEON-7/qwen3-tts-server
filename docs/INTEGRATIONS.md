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

```bash
# disable the old whisper.cpp + ElevenLabs paths
WHISPER_ENABLED=false
# ELEVENLABS_API_KEY=        # leave unset

# pair with qwen3-asr-server for the speech recognition leg
STT_BACKEND=qwen
ASR_ENDPOINT=http://${SPARK_HOST}:8001/v1/audio/transcriptions
ASR_MODEL=qwen3-asr
ASR_LANGUAGE=en

# wire to qwen3-tts-server (this repo)
TTS_BACKEND=qwen
TTS_ENDPOINT=http://${SPARK_HOST}:8002/v1/audio/speech
TTS_MODEL=qwen3-tts
TTS_VOICE="A warm, expressive adult voice with natural cadence."

# wire LLM main
LLM_BASE_URL=http://${SPARK_HOST}:8000/v1
LLM_MODEL=qwen36-ultimate-xs
LLM_API_KEY=ignored          # any non-empty string works
```

### Audio format on the wire

- This server returns **WAV (24 kHz mono 16-bit PCM by default)**.
  matrix-voip-agent strips the RIFF header (`data` chunk offset) and pipes
  the raw PCM to `pw-play -r 24000 -f s16 -c 1`.
- If you're rolling your own bridge, that's the contract: POST JSON with
  `input` text, get back WAV bytes. Read the sample rate from the WAV
  header (offset 24, little-endian uint32) — don't hardcode 24 kHz on the
  client side, future model variants may differ.

---

## 2. OpenAI SDK (Python / TS / anywhere)

This server speaks OpenAI's `/v1/audio/speech`. Drop in any OpenAI SDK
and point `base_url` at it:

### Python

```python
from openai import OpenAI

client = OpenAI(base_url=f"http://{SPARK_HOST}:8002/v1", api_key="ignored")

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
  apiKey: "ignored",
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
  TTS API Key:      ignored
  TTS Model:        qwen3-tts
  TTS Voice:        A warm, expressive adult voice.
```

The "voice" field is sent as the OpenAI `voice` param, which this server
forwards to qwen-tts as the `instruct` description — so any natural-language
voice description works.

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

Request body fields:

| field             | required | notes                                                      |
| ----------------- | :------: | ---------------------------------------------------------- |
| `input`           |    ✓     | Text to synthesize.                                        |
| `model`           |          | Defaults to `qwen3-tts` (the served-model-name).           |
| `voice`           |          | Free-form voice description. Defaults to `QWEN_TTS_DEFAULT_VOICE`. |
| `response_format` |          | `wav` (default), `flac`, or `mp3`.                         |
| `language`        |          | One of `zh`, `en`, `ja`, `ko`, `de`, `fr`, `ru`, `pt`, `es`, `it`. Auto-detect if omitted. |

The endpoint accepts any `Authorization` header (no real auth — put a proxy
in front for any non-trusted network).

---

## 6. Other LLM-orchestrated agents (LangChain, LlamaIndex, custom)

Anything that consumes an OpenAI TTS-compatible base URL works unchanged.
The deciding fact is the `/v1/audio/speech` shape, not the underlying
engine. If your framework's TTS abstraction lets you set a custom
`base_url` + `api_key`, it'll work here.

---

## A note on running this image elsewhere

Nothing in the image is Spark-specific *except* the flash-attn 2 wheel,
which is built for `sm_120`. On other Blackwell / consumer / datacenter
GPUs the image will boot — flash-attn auto-falls back to SDPA at runtime
if the kernel can't load. Re-build with the right `FLASH_ATTN_CUDA_ARCHS`
if you want native flash-attn there too.
