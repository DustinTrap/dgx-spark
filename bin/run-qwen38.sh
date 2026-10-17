#!/usr/bin/env bash
# Qwen3.8-Flash-Next (125B main + 51B n-gram, 6B active) on the DGX Spark via vLLM.
#
# The checkpoint is ~125 GiB of NVFP4, which does not fit next to a usable KV cache
# in the 121GB unified pool. 48 GiB of it is the n-gram ("PLE") lookup table, and a
# token only touches 16 rows of it, so the qwen3.8-Flash-DGX recipe mmaps that table
# from NVMe instead of keeping it resident: ~75 GiB resident, the rest goes to KV.
# See ~/ai-stack/qwen38-flash/README.md.
#
# This is a thin wrapper around that recipe's own scripts/serve.sh, which is the
# tested launcher - we do not reimplement its flag set. What we add is what
# llama-swap needs:
#   - the port llama-swap assigned, instead of the recipe's fixed 18300
#   - no docker restart policy: llama-swap owns this container's lifecycle, and a
#     container that resurrects itself after a swap would hold ~75 GiB hostage
#   - a foreground process, because llama-swap tracks the command it started while
#     serve.sh starts the container detached and returns
set -euo pipefail

PORT="${1:?usage: run-qwen38.sh <host-port>}"
NAME=qwen38-flash
RECIPE="$HOME/ai-stack/qwen38-flash"
MODEL=nvidia/Qwen3.8-Flash-Next-NVFP4
REPO_DIR="$HOME/.cache/huggingface/hub/models--${MODEL//\//--}"

[ -x "$RECIPE/scripts/serve.sh" ] || { echo "recipe not found at $RECIPE" >&2; exit 1; }
docker image inspect qwen38-flash-dgx >/dev/null 2>&1 || {
  echo "image qwen38-flash-dgx missing - build it first:" >&2
  echo "  docker build -t qwen38-flash-dgx $RECIPE" >&2
  exit 1
}

# The hybrid layout (NVFP4 experts + fp8 side layers) decodes ~20% faster at the
# same quality, but it is a one-time prepare step. Use it when it is there, and
# fall back to the checkpoint as published rather than refusing to start.
MODE=nvfp4
if compgen -G "$REPO_DIR/snapshots/*-fp8hybrid/.prepared" >/dev/null 2>&1; then
  MODE=hybrid
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

# Recipe defaults we keep: MTP=2, prefix caching on, deterministic top-k,
# reduced draft vocabulary, GPU_MEM=0.80 (0.85 drifted into swap on this box
# after a day; 0.875 got OOM-killed on a long prefill).
#
# Native 262,144-token window, no YaRN (issue #30). vLLM applies YaRN statically -
# to every request, however short - and the model card advises enabling it only
# when long context is actually needed. Coding agents here compact at ~140k; in
# the 10 days before the switch, 9 of 12,351 prompts were over 200k tokens
# (vllm:request_prompt_tokens histogram). A prompt over 262,144 now gets a 400
# instead of being served. For a long-context window, set both
# YARN=1 and CTX_LEN (up to 500000) in this model's llama-swap env; CTX_LEN above
# 262144 without YARN=1 is refused by vLLM at startup.
MODE="$MODE" YARN="${YARN:-0}" CTX="${CTX_LEN:-262144}" PORT="$PORT" NAME="$NAME" \
  "$RECIPE/scripts/serve.sh"

# serve.sh sets --restart unless-stopped; llama-swap must be the only thing
# deciding when this model is resident.
docker update --restart=no "$NAME" >/dev/null 2>&1 || true

# Stay in the foreground for llama-swap. Weights take 8-13 min to load on first
# boot, which is why llama-swap.yaml sets healthCheckTimeout to 1800.
exec docker wait "$NAME"
