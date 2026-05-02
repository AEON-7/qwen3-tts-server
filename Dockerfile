# Thin TTS sidecar — reuses the v3 vLLM image's Python/torch/audio stack
# (aarch64-native, has librosa/soundfile already). Adds qwen-tts + FastAPI.
FROM ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v3

# qwen-tts depends on `sox` system binary for some audio I/O paths
RUN apt-get update && apt-get install -y --no-install-recommends sox libsox-fmt-all \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --break-system-packages \
      "qwen-tts" \
      "fastapi>=0.110" \
      "uvicorn[standard]>=0.27" \
      "pydantic>=2.5"

# flash-attn for max throughput. The qwen-asr README explicitly recommends this
# install style ("--no-build-isolation"). We don't need to compile from source if
# a prebuilt wheel matches our torch+cuda+arch combo; pip will fall back to source
# build if it doesn't (slow first build, ~10-15 min on Spark, baked into image).
# Cap MAX_JOBS to keep memory pressure down on Spark's unified RAM during the
# native build; 4 is conservative for a 20-core ARM with 128GB but keeps the
# build stable.
# NOTE: Kept above the vllm[audio] line so this expensive layer stays cached
# across small dep tweaks below.
ENV MAX_JOBS=4 \
    FLASH_ATTN_CUDA_ARCHS=120
RUN pip install --no-cache-dir --break-system-packages --no-build-isolation \
      "flash-attn>=2.7" \
 || (echo "flash-attn install failed; will fall back to sdpa at runtime" && true)

# vLLM's audio decode path needs `av` (PyAV) as the container-format fallback
# (M4A / WebM / MP4 / odd WAVs that soundfile can't sniff from a BytesIO).
# `soundfile` itself is already pulled in transitively by qwen-tts above.
#
# We install `av` ALONE with --no-deps because the full `vllm[audio]` extra
# re-resolves vLLM's core deps and downgrades flashinfer + apache-tvm-ffi,
# which silently regresses TTS inference latency by ~5x. PyAV is the only
# missing piece — soundfile is already there.
RUN pip install --no-cache-dir --break-system-packages --no-deps "av>=12"

WORKDIR /app
COPY server.py /app/server.py

ENV PYTHONUNBUFFERED=1
EXPOSE 8002
CMD ["python3", "server.py"]
