#!/usr/bin/env bash
# gpt-oss-120b on DGX Spark via llama.cpp.
#
# Why llama.cpp and not SGLang: lmsysorg/sglang:spark hangs indefinitely after
# loading the safetensors shards for this model on GB10 - sgl-project/sglang
# issue #13382, still unresolved. It exhausted all RAM and swap here twice,
# stalling at the identical point both times (after shards load, before KV
# cache allocation), at default mem-fraction and at 0.75. mem-fraction is not
# the lever. The original SGLang launcher is kept at run-gpt-oss-sglang.sh.disabled.
#
# Why this GGUF and not the Ollama blob: Ollama writes its own architecture
# name into the GGUF header ("gptoss"), which upstream llama.cpp rejects with
# "unknown model architecture". ggml-org/gpt-oss-120b-GGUF is the stock
# conversion, 63.4GB MXFP4, and loads directly.
#
# Container image is NVIDIA's own llama.cpp build for Spark (arm64, sm121),
# taken from the nemoclaw managed-inference catalog.
set -euo pipefail

PORT="${1:?usage: run-gpt-oss.sh <host-port>}"
NAME=gpt-oss-120b
IMAGE='ghcr.io/nvidia/nemoclaw/llama-cpp-server@sha256:9d0cddd7bcaf98d3b75a7fc8c7ce3af3a9973b5f23a8092e7e93a9afc473a675'

# HF stores snapshot entries as symlinks into ../../blobs, which a bind mount
# of the snapshot directory alone would not resolve inside the container.
# Resolve to the blob and mount that single file.
SNAP_GLOB="$HOME/.cache/huggingface/hub/models--ggml-org--gpt-oss-120b-GGUF/snapshots"/*/gpt-oss-120b-MXFP4.gguf
GGUF="$(readlink -f $SNAP_GLOB 2>/dev/null || true)"
[ -n "$GGUF" ] && [ -f "$GGUF" ] || {
  echo "gpt-oss GGUF not found (still downloading?): $SNAP_GLOB" >&2
  exit 1
}

docker rm -f "$NAME" >/dev/null 2>&1 || true

# 63.4GB of weights on a 121GB unified pool, and the KV cache is cheap here:
# 8 KV heads x 64 dim x 2 (K+V) x 2 bytes = 2KiB per token per layer, and only
# half of the 36 layers hold a full cache (the others use a 128-token sliding
# window), so 128k context costs ~4.5GiB. Model's own limit is 131072 - that,
# not memory, is the ceiling. Lower it with CTX_LEN if you want the headroom.
exec docker run --name "$NAME" --rm \
  --gpus all \
  --user "$(id -u):$(id -g)" \
  -p "127.0.0.1:${PORT}:8081" \
  -v "$GGUF:/models/gpt-oss-120b-MXFP4.gguf:ro" \
  "$IMAGE" \
    --model /models/gpt-oss-120b-MXFP4.gguf \
    --alias gpt-oss-120b \
    --host 0.0.0.0 --port 8081 \
    --n-gpu-layers 999 \
    --ctx-size "${CTX_LEN:-131072}" \
    --parallel 1 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --flash-attn on \
    --cache-type-k f16 \
    --cache-type-v f16 \
    --jinja
