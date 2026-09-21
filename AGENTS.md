# AGENTS.md — rules for anyone (human or AI agent) working in this repo

Self-contained on purpose: some harnesses load only this file. Read all of it.

## 1. This repository is PUBLIC

Everything you write is world-readable forever: files, commit messages, branch
names, PR text, issue comments, CI logs. Never put any of these anywhere in it:

- a token or key **value**, or a fingerprint / prefix / hash / length of one;
- a private-network IP address or subnet — write `<spark-ip>` and `<lan-cidr>`,
  the placeholders the README already uses (loopback and `0.0.0.0` are fine);
- the hostname of any other machine; an email address; an absolute home path
  (`/home/<name>/…`, `/Users/<name>/…`) — use `~` or `$HOME`;
- the name of, or any identifier for, a person who uses the endpoint;
- **any detail about the applications that consume this endpoint**: names,
  repositories, prompts, payloads, logs, traffic patterns tied to one of them.
  Describe consumers only generically — "coding agents", "a latency-sensitive
  dashboard client", "a web UI". Evidence from a consuming application stays in
  that application's own tracker. Do not name other repositories.

If unsure whether something is disclosable, it is not. If something sensitive
was already pushed, say so on the issue **without repeating it**; a leaked token
is rotated, not just deleted.

## 2. The box is shared — treat it as production

The DGX Spark this repo describes serves **several different solutions at
once**. A model reload takes **~13 minutes**, and that is downtime for every
consumer, not just yours. Therefore, without an issue **and** an announced
window:

- no restarts (llama-swap, the container, Docker, the host) and no key rotation;
- no load tests or benchmarks — one long prefill drops everyone else's decode to
  1–6 tok/s. `scripts/depth-concurrency.sh` refuses to run without
  `ANNOUNCED_ISSUE`; `DRY_RUN=1` prints its plan and contacts nothing;
- no config changes on the box (`llama-swap.yaml` is watched and reloads live).

Having repo access does not mean you have, or should seek, access to the box.
If your task is repo-only, do not ssh anywhere or call the endpoint.

## 3. Issue first

Find or file the GitHub issue before you change anything, state your intent on
it, and update it as work lands. This **includes changes made directly on the
box**: the issue records what changed, when, and how to undo it, and the repo is
then brought back in line. The tracker, not chat or agent memory, is the record.

## 4. Numbers cite their source

Every figure states the command that produced it. Benchmark figures also state
their conditions: date, tool and version, model layout, concurrency, context
depth, cache warm or cold, measured client-side or engine-side, and what else
was using the box. No command, no number — write "not measured" instead.
Say plainly what you did **not** verify.

## 5. Git hygiene

- **Never `git add -A`, `git add .` or `git commit -a`.** Stage files by name.
  The `secrets/` and `*.env` ignore rules are the only thing between a bearer
  token and a public commit. Never read or print `secrets/` or a real `*.env`.
- Benchmark logs go through `scripts/scrub-paths.sh` before they are committed.
- Enable the hook once per clone: `git config core.hooksPath .githooks`. CI runs
  the same gitleaks rules (`.gitleaks.toml`) on every push and PR; see
  `docs/secret-scanning.md`. Do not weaken a rule or add an allowlist entry to
  get a change through — fix the change.
- Work on a branch, open a PR into `main`; do not push to `main` or merge your
  own PR unless the operator asked you to.

## 6. Done means clean

Done = the issue is updated; `git status` is clean (no stray files, scratch
copies or half-staged work); scripts you touched pass `bash -n`; gitleaks passes
over the tree and full history; anything you planted to prove a guardrail works
is removed; and your report lists what was not done and not verified.

## 7. Commit trailer

End every agent-authored commit message with a trailer naming the agent/model,
so authorship is auditable from `git log` alone. Use the vendor's no-reply
address, never a personal email:

    Co-Authored-By: <agent or model name + version> <noreply@vendor-domain>
