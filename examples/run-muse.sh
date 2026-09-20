#!/usr/bin/env bash
# Muse Glimmer 30B on DGX Spark via llama.cpp.
# Parameters taken from NVIDIA nemoclaw serving recipe
# llama-cpp.muse-glimmer-30b.spark-single.v1
set -euo pipefail

PORT="${1:?usage: run-muse.sh <host-port>}"
NAME=muse-glimmer
IMAGE='ghcr.io/nvidia/nemoclaw/llama-cpp-server@sha256:9d0cddd7bcaf98d3b75a7fc8c7ce3af3a9973b5f23a8092e7e93a9afc473a675'
REV=43c7eadd41352a299ea8e0a36b3157978dd63596
GGUF_FILE=Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf

# HF snapshot entries are symlinks into ../../blobs, which a bind mount of the
# snapshot directory alone would not resolve inside the container. Resolve to
# the blob and mount that single file.
GGUF="$(readlink -f "$HOME/.cache/huggingface/hub/models--meta-models--Muse-Glimmer-30B-GGUF/snapshots/$REV/$GGUF_FILE" 2>/dev/null || true)"
[ -n "$GGUF" ] && [ -f "$GGUF" ] || { echo "Muse GGUF not found for revision $REV" >&2; exit 1; }

docker rm -f "$NAME" >/dev/null 2>&1 || true

exec docker run --name "$NAME" --rm \
  --gpus all \
  --user "$(id -u):$(id -g)" \
  -p "127.0.0.1:${PORT}:8081" \
  -v "$GGUF:/models/$GGUF_FILE:ro" \
  "$IMAGE" \
    --model "/models/$GGUF_FILE" \
    --alias muse-glimmer \
    --host 0.0.0.0 --port 8081 \
    --n-gpu-layers 999 \
    --ctx-size 131072 \
    --parallel 1 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --flash-attn on \
    --cache-type-k f16 \
    --cache-type-v f16 \
    --jinja
