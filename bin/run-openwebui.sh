#!/usr/bin/env bash
# Open WebUI pointed at llama-swap. The model selector lists every model in
# llama-swap.yaml; picking one loads it on demand.
set -euo pipefail

# Open WebUI gets its OWN key (consumer name: webui), not a key shared with any
# other client, so it can be revoked or rotated alone. The key is baked into
# the container environment: after changing LLM_KEY_WEBUI, re-run this script,
# or Open WebUI keeps presenting the old key and silently gets 401.
. "$HOME/ai-stack/secrets/api-key.env"
: "${LLM_KEY_WEBUI:?LLM_KEY_WEBUI is not set in ~/ai-stack/secrets/api-key.env}"
NAME=open-webui
# Passed to docker by NAME (--env OPENAI_API_KEY, no "=value") so the key never
# appears on a command line, i.e. not in the process list or shell history.
export OPENAI_API_KEY="$LLM_KEY_WEBUI"

docker rm -f "$NAME" >/dev/null 2>&1 || true

exec docker run -d --name "$NAME" \
  --restart unless-stopped \
  -p 3000:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --env "OPENAI_API_BASE_URL=http://host.docker.internal:9292/v1" \
  --env OPENAI_API_KEY \
  --env "ENABLE_OLLAMA_API=false" \
  --env "ENABLE_TAGS_GENERATION=false" \
  --env "WEBUI_NAME=Spark" \
  ghcr.io/open-webui/open-webui:main
