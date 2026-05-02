# Supported TTS Models

The deploy script (`deploy/deploy-tts.sh`) accepts any of the variants below.
Pick interactively or set the `QWEN_TTS_MODEL` env var to skip the prompt.

The image is **officially validated** with:

- **`Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`** — the deploy-script default

Other variants are supported but unbenchmarked on this image — they should
"just work" because they share architecture with the validated one.

## Qwen3-TTS family

All variants share the codec tokenizer **`Qwen/Qwen3-TTS-Tokenizer-12Hz`**
(12.5 Hz, 16-codebook audio codec). Auto-pulled — you don't need to set
it unless using a custom fork.

| Repo ID                                        | Params | Variant       | When to pick                                                                                            | Status              |
| ---------------------------------------------- | -----: | ------------- | ------------------------------------------------------------------------------------------------------- | ------------------- |
| `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`         |  1.7B  | VoiceDesign   | Generate brand-new voices from a natural-language description (timbre / age / accent / emotion). Streaming + instruction control. | ✅ validated default |
| `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice`         |  1.7B  | CustomVoice   | 9 fixed premium speakers + instruction-driven style control (zh dialects, en, ja, ko). Streaming + instruct. | user-selectable     |
| `Qwen/Qwen3-TTS-12Hz-1.7B-Base`                |  1.7B  | Base          | 3-second zero-shot voice cloning from a reference audio; intended fine-tuning base.                     | user-selectable     |
| `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`         |  0.6B  | CustomVoice   | Same 9 speakers as 1.7B, smaller / faster, **no** instruction control.                                  | user-selectable     |
| `Qwen/Qwen3-TTS-12Hz-0.6B-Base`                |  0.6B  | Base          | Smallest variant, 3-second zero-shot voice clone / fine-tuning base, no instruct.                       | user-selectable     |

## Picking the right variant

- **Want to *describe* a voice in words?** → **VoiceDesign 1.7B** (default).
  Best for "an elderly French man with a smoker's voice" / character-driven apps.
- **Want to *clone* an existing voice from a 3-sec sample?** → **Base** (1.7B
  for quality, 0.6B for speed). Best for personalization / branded voice.
- **Want a fixed catalog of speakers + style instructions?** → **CustomVoice 1.7B**.
  Best when you need consistent voices across sessions.
- **Want the cheapest fixed-speaker option?** → **CustomVoice 0.6B**.
  Best for high-throughput batch synthesis.

## Memory tuning

Numbers are for **DGX Spark** (128 GB unified). Adjust proportionally on
other GPUs.

| variant      | resident      | notes                                                |
| ------------ | ------------- | ---------------------------------------------------- |
| 0.6B         | ~2 GB CUDA    | Tiny footprint; multi-instance friendly.             |
| 1.7B         | ~4 GB CUDA    | Comfortable next to a 27B LLM main on a single Spark.|

(TTS uses `transformers` directly, not vLLM — so there's no
`--gpu-memory-utilization` knob. The model just allocates what it needs.)

## Audio output format

Default WAV output: **24 kHz mono 16-bit PCM**. The exact sample rate
comes from the model — don't hardcode 24 kHz on the client side; read the
RIFF header and respect what arrives.

The server also supports `flac` (lossless, smaller) and `mp3` (needs system
`libmp3lame`, which the image ships).

## Languages supported

All variants support: `auto`, `chinese`, `english`, `french`, `german`,
`italian`, `japanese`, `korean`, `portuguese`, `russian`, `spanish`.

The OpenAI body field is short codes (`zh`, `en`, `ja`, ...) which the
server maps via the underlying SDK. Pass `language=null` (or omit the
field) to let the model auto-detect from the input text.
