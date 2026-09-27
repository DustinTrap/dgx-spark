#!/usr/bin/env bash
# SearXNG for Open WebUI's web search. Re-running recreates the container.
#
# No port is published: SearXNG is reachable only from containers on the add-on
# network, so nothing new is exposed to the LAN and no ufw rule is needed. Open
# WebUI joins that network as a second network (bin/run-openwebui.sh) and
# queries http://searxng:8080/search.
set -euo pipefail

NAME=searxng
NET=webui-addons
# SearXNG publishes date-stamped tags; bump this deliberately.
IMAGE=searxng/searxng:2026.9.25-12f8b6515
SETTINGS="$HOME/ai-stack/searxng/settings.yml"
[ -f "$SETTINGS" ] || { echo "missing $SETTINGS - copy searxng/settings.yml from the repo" >&2; exit 1; }

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# The secret signs only SearXNG's own cookies and image-proxy links, which an API
# client never uses, so a fresh one per start leaves nothing to store. Passed to
# docker by NAME, so it never appears on a command line.
SEARXNG_SECRET="$(openssl rand -hex 32)"
export SEARXNG_SECRET

# -v also drops the anonymous volumes the image declares, so re-runs do not pile them up.
docker rm -f -v "$NAME" >/dev/null 2>&1 || true

# FORCE_OWNERSHIP=false: otherwise the entrypoint runs chown -R on /etc/searxng,
# which contains the read-only bind mount of the settings file.
# --memory caps it on a box that is short of RAM; one worker uses a few hundred MiB.
docker run -d --name "$NAME" \
  --restart unless-stopped \
  --network "$NET" \
  --memory 1g \
  --env SEARXNG_SECRET \
  --env FORCE_OWNERSHIP=false \
  -v "$SETTINGS:/etc/searxng/settings.yml:ro" \
  "$IMAGE"

# A web UI that is already running joins the network here. When bin/run-openwebui.sh
# recreates the web UI, it joins the network itself.
if docker inspect open-webui >/dev/null 2>&1 &&
  ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' open-webui | grep -qx "$NET"; then
  docker network connect "$NET" open-webui
fi
