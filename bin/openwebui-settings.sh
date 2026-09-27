#!/usr/bin/env bash
# The Open WebUI settings this stack depends on, applied to the running container.
# Idempotent; prints each value before and after.
#
# Open WebUI 0.11 keeps its settings in its own database (`config` table) and a
# stored value wins over the container environment (README -> Open WebUI), so
# they are set here, not in bin/run-openwebui.sh. 0.11 reads these rows on every
# use, so no restart is needed, with one exception, printed when it applies.
set -euo pipefail
NAME=open-webui

STARTED="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$NAME")" +%s)"
docker exec -i -e STARTED="$STARTED" "$NAME" python3 - <<'PY'
import json, os, sqlite3, time

SETTINGS = {
    # The endpoint runs 8 sequences (concurrencyLimit: 8 in llama-swap.yaml).
    # Foreground and background sub-agents have separate budgets that add up,
    # so sub-agents can hold at most 3 of the 8.
    'subagents.max_concurrent': 2,
    'subagents.max_async': 1,
    # Web search through SearXNG on the add-on network (bin/run-searxng.sh).
    'web.search.enable': True,
    'web.search.engine': 'searxng',
    'web.search.searxng_query_url': 'http://searxng:8080/search',
    # Characters one fetch_url call may add to a prompt (default: unlimited).
    'web.fetch.max_content_length': 20000,
}

db = sqlite3.connect('/app/backend/data/webui.db', timeout=30)
def get(key):
    row = db.execute('select value from config where key=?', (key,)).fetchone()
    return row[0] if row else None

before = {key: get(key) for key in SETTINGS}
now = int(time.time())
with db:
    for key, value in SETTINGS.items():
        # Stored the way Open WebUI stores them: JSON text in the value column.
        db.execute(
            'insert into config (key, value, updated_at) values (?, ?, ?) '
            'on conflict(key) do update set value=excluded.value, updated_at=excluded.updated_at',
            (key, json.dumps(value), now),
        )
for key in SETTINGS:
    print(f'{key}: {before[key]} -> {get(key)}')

# The foreground sub-agent limit is read once per process: utils/subagents.py
# sizes a semaphore when the first foreground sub-agent runs, and keeps it.
ran = db.execute(
    "select count(*) from chat where title like 'Sub-agent:%' and created_at >= ?",
    (int(os.environ['STARTED']),),
).fetchone()[0]
if ran:
    print(f'NOTE: {ran} sub-agent chat(s) since the container started, so the running process '
          'keeps its old foreground limit until `docker restart open-webui`.')
PY
