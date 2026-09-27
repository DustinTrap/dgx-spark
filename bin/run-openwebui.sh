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

docker run -d --name "$NAME" \
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

# Second network: reach the add-on containers (SearXNG, bin/run-searxng.sh) by
# name. It is joined after creation, so the primary network stays the default
# bridge and the path to llama-swap through the host gateway, and the ufw rule
# that admits it, are unchanged.
ADDONS_NET=webui-addons
docker network inspect "$ADDONS_NET" >/dev/null 2>&1 || docker network create "$ADDONS_NET" >/dev/null
docker network connect "$ADDONS_NET" "$NAME"
