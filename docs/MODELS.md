# Supported Models

Both deploy scripts (`deploy/deploy-tts.sh`, `deploy/deploy-asr.sh`) accept
any of the variants listed below — pick interactively, or set the
`QWEN_TTS_MODEL` / `QWEN_ASR_MODEL` env var to skip the prompt.

The image is **officially validated** with:

- **TTS** — `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`
- **ASR** — `Qwen/Qwen3-ASR-0.6B`

These are the deploy-script defaults. Other variants are supported but
unbenchmarked on this image — they should "just work" because they share
architecture with the validated ones, but you may need to tune
`gpu-memory-utilization` for 1.7B ASR.

## Qwen3-TTS family

All variants share the codec tokenizer **`Qwen/Qwen3-TTS-Tokenizer-12Hz`**
(12.5 Hz, 16-codebook audio codec). This is auto-pulled — you don't need
to set it unless you're using a custom fork.

| Repo ID                                        | Params | Variant       | When to pick                                                                                            | Status              |
| ---------------------------------------------- | -----: | ------------- | ------------------------------------------------------------------------------------------------------- | ------------------- |
| `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`         |  1.7B  | VoiceDesign   | Generate brand-new voices from a natural-language description (timbre / age / accent / emotion). Streaming + instruction control. | ✅ validated default |
| `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice`         |  1.7B  | CustomVoice   | 9 fixed premium speakers + instruction-driven style control (zh dialects, en, ja, ko). Streaming + instruct. | user-selectable     |
| `Qwen/Qwen3-TTS-12Hz-1.7B-Base`                |  1.7B  | Base          | 3-second zero-shot voice cloning from a reference audio; intended fine-tuning base.                     | user-selectable     |
| `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`         |  0.6B  | CustomVoice   | Same 9 speakers as 1.7B, smaller / faster, **no** instruction control.                                  | user-selectable     |
| `Qwen/Qwen3-TTS-12Hz-0.6B-Base`                |  0.6B  | Base          | Smallest variant, 3-second zero-shot voice clone / fine-tuning base, no instruct.                       | user-selectable     |

### Picking the right variant

- Want to *describe* a voice in words? → **VoiceDesign 1.7B** (default).
- Want to *clone* an existing voice from a 3-second sample? → **Base** (1.7B
  for quality, 0.6B for speed).
- Want a fixed catalog of speakers + style instructions? → **CustomVoice 1.7B**.
- Want the cheapest fixed-speaker option? → **CustomVoice 0.6B**.

## Qwen3-ASR family

There is no separate ASR tokenizer repo — the audio encoder is in-model.

| Repo ID                       | Params | Variant   | When to pick                                                                  | Status              |
| ----------------------------- | -----: | --------- | ----------------------------------------------------------------------------- | ------------------- |
| `Qwen/Qwen3-ASR-0.6B`         |  0.6B  | ASR small | 30 langs + 22 zh dialects, very high throughput (~2000× at concurrency 128).  | ✅ validated default |
| `Qwen/Qwen3-ASR-1.7B`         |  1.7B  | ASR large | Same coverage, SOTA WER among open ASR. Pick when accuracy > throughput.      | user-selectable     |
| `Qwen/Qwen3-ForcedAligner-0.6B` | 0.6B | Aligner   | Optional companion for word/phoneme timestamps (≤ 5 min audio, 11 langs).     | optional companion  |

### Picking the right variant

- Real-time / interactive ASR? → **0.6B** (default; RTF 16-20× on Spark).
- Best WER, throughput is secondary? → **1.7B** (bump `GPU_MEM` to ~0.16).
- Need word-level timestamps? → run **ForcedAligner-0.6B** as a separate
  endpoint (out of scope for this image; the deploy scripts don't ship it).

## Memory tuning

These numbers are for **DGX Spark** (128 GB unified). Adjust proportionally
on other GPUs.

| variant      | `--gpu-memory-utilization` | typical resident |
| ------------ | -------------------------- | ---------------- |
| TTS 0.6B     | n/a (transformers, not vLLM) | ~2 GB CUDA     |
| TTS 1.7B     | n/a (transformers, not vLLM) | ~4 GB CUDA     |
| ASR 0.6B     | `0.06`–`0.08`              | ~5–10 GB        |
| ASR 1.7B     | `0.14`–`0.18`              | ~18–22 GB       |

If ASR boots and immediately exits with `No available memory for the cache
blocks`, raise `GPU_MEM` by 0.02 and retry. If you see boot-loops past 3
restarts, lower `MAX_LEN` first (default 8192 is generous for ASR).
