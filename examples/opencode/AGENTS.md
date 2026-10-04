# Delegation (tool `subagent`, parameter `agent`)

Call `subagent` BEFORE reading files yourself when:
1. The answer needs more than 3 files or a directory sweep → `agent: explore` (state thoroughness: quick / medium / very thorough).
2. The request names independent parts (files, modules, checks, hosts) → one `agent: general` per part, all launched in the same turn. Cap at 3 parallel subagents; the inference server is shared. Before launching more than one, run `wait-for-slot --check --need <number of subagents>` in the shell. If it does not exit 0, launch them one at a time instead.
3. A diff, PR, or change set needs review or an adversarial pass → `agent: reviewer`.

Rules:
- Give each subagent all the context it needs; child sessions start empty.
- Never repeat work you delegated. Summarize the result for the user with file:line evidence.
- Independent tool calls go in one turn, not one at a time.
- Never read a whole repository into the main session.
