# OpenCode client profile for this endpoint

Copy the three files into `~/.config/opencode/` (issue #14 has the measurements behind each setting).

| Setting | Why |
|---|---|
| `compaction.reserved: 360000` | OpenCode compacts at `context − max(32k, reserved)`. With the model declared at 500k that is 468k, so compaction never ran; 360k makes it run near 140k tokens per turn, inside the native 262k window. |
| `permission.skill` deny, `tools.execute: false` | OpenCode auto-discovers skills from `~/.claude/skills` and `~/.agents/skills` and lists every description on every turn (~6k tokens here), plus a desktop-browser catalog (~2k). Allow-list the skills you actually use. |
| `tool_output` 800 lines / 24 KiB | Halves per-result context growth; full output is still saved to disk with a pointer. |
| variants in `opencode.jsonc` | Agent-level `temperature`/`top_p` are never sent by 2.0.11; a variant body is. Values are Qwen's published thinking / non-thinking sets. |
| `build.permission.subagent` allow-list | A short subagent menu makes delegation picks reliable; the base prompt for this model family contains no delegation guidance, so `AGENTS.md` carries it, capped at 3 parallel subagents (8 vLLM slots are shared). |
| `wait-for-slot` in `AGENTS.md` | The cap of 3 does not look at what other consumers are running. [`scripts/wait-for-slot.sh`](../../scripts/wait-for-slot.sh) reads the endpoint's own running and waiting counts (issue #23). One sub-agent at a time is the fallback because the parent session waits on the tool call while the sub-agent runs, so it should add no request (expected from how the tool works, not measured). |

`AGENTS.md` calls the gate as `wait-for-slot`, so put a wrapper with that name on your `PATH`. The address and the key file stay on your machine:

```bash
#!/usr/bin/env bash
# ~/.local/bin/wait-for-slot
exec ~/src/dgx-spark/scripts/wait-for-slot.sh --key-file ~/.config/opencode/llama-swap.key "$@" http://<spark-ip>:9292
```

Checked 2026-10-05 (issue #25) with OpenCode 2.0.23, these files, the `#high` variant and `opencode run --standalone --auto --format json` on a prompt that names three independent files, one run per case. With room, the model ran `wait-for-slot --check --need 3` first and then launched three sub-agents in one turn, which ran in parallel. With a stub `wait-for-slot` first on `PATH` that exits 1, it launched them one at a time and told the user why. One run each, so the model's choice can still vary. To repeat the busy case without loading the endpoint, run this in a scratch directory (`--standalone` matters: the background service has its own `PATH`):

```bash
mkdir -p /tmp/busy-gate
printf '#!/usr/bin/env bash\necho "busy: running=6 waiting=1 need=3 limit=6" >&2\nexit 1\n' >/tmp/busy-gate/wait-for-slot
chmod +x /tmp/busy-gate/wait-for-slot
PATH=/tmp/busy-gate:$PATH opencode run --standalone --auto --format json \
  "This directory has three independent files: a.txt, b.txt and c.txt. Treat each file as a separate part and report its line count."
```

Check the client log after any config change: a key that validates against the schema can still be dropped at load time (`configuration normalization diagnostic … omitted unsupported legacy setting`).
