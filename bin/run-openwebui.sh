#!/usr/bin/env bash
# Open WebUI pointed at llama-swap. The model selector lists every model in
# llama-swap.yaml; picking one loads it on demand.
set -euo pipefail

. "$HOME/ai-stack/secrets/api-key.env"
NAME=open-webui

docker rm -f "$NAME" >/dev/null 2>&1 || true

exec docker run -d --name "$NAME" \
  --restart unless-stopped \
  -p 3000:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --env "OPENAI_API_BASE_URL=http://host.docker.internal:9292/v1" \
  --env "OPENAI_API_KEY=${LLM_API_KEY}" \
  --env "ENABLE_OLLAMA_API=false" \
  --env "ENABLE_TAGS_GENERATION=false" \
  --env "WEBUI_NAME=Spark" \
  ghcr.io/open-webui/open-webui:main
