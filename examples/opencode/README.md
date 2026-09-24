# OpenCode client profile for this endpoint

Copy the three files into `~/.config/opencode/` (issue #14 has the measurements behind each setting).

| Setting | Why |
|---|---|
| `compaction.reserved: 360000` | OpenCode compacts at `context − max(32k, reserved)`. With the model declared at 500k that is 468k, so compaction never ran; 360k makes it run near 140k tokens per turn, inside the native 262k window. |
| `permission.skill` deny, `tools.execute: false` | OpenCode auto-discovers skills from `~/.claude/skills` and `~/.agents/skills` and lists every description on every turn (~6k tokens here), plus a desktop-browser catalog (~2k). Allow-list the skills you actually use. |
| `tool_output` 800 lines / 24 KiB | Halves per-result context growth; full output is still saved to disk with a pointer. |
| variants in `opencode.jsonc` | Agent-level `temperature`/`top_p` are never sent by 2.0.11; a variant body is. Values are Qwen's published thinking / non-thinking sets. |
| `build.permission.subagent` allow-list | A short subagent menu makes delegation picks reliable; the base prompt for this model family contains no delegation guidance, so `AGENTS.md` carries it, capped at 3 parallel subagents (8 vLLM slots are shared). |

Check the client log after any config change: a key that validates against the schema can still be dropped at load time (`configuration normalization diagnostic … omitted unsupported legacy setting`).
