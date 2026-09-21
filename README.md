# DGX Spark inference stack

Serving **Qwen3.8-Flash-Next** (176B total, 6B active) on a **single NVIDIA DGX
Spark** — one GB10 superchip, 128 GB unified memory — as an OpenAI- and
Anthropic-compatible API for coding agents, with Open WebUI in front of it.

The whole point of this repo is that the model does not, on paper, fit. The
NVFP4 checkpoint is ~125 GiB and the box has 121 GiB usable. It fits because
48 GiB of that checkpoint is an n-gram lookup table that gets served from NVMe
instead of memory. Details under [How it fits](#how-it-fits).

---

## The stack

```
  coding agent / Open WebUI
            |
            |  http://<spark-ip>:9292/v1      one bearer key per consumer, LAN only
            v
      llama-swap  ......................  auth, model lifecycle, OpenAI surface
            |
            |  http://127.0.0.1:10001       loopback only, no auth
            v
        vLLM  ..........................  qwen38-flash-dgx image
            |
            +-- weights, NVFP4 + fp8 hybrid    ~75 GiB resident
            +-- KV cache                       19.5 GiB / 721,212 tokens
            +-- PLE n-gram table               47.7 GiB, mmap'd from NVMe
```

llama-swap is kept even though only one model is served: it owns the bearer
keys (one per consumer, see [Keys and rotation](#keys-and-rotation)), the
`0.0.0.0:9292` surface every client already points at, and the process
lifecycle. vLLM itself has no authentication, which is why its port is
bound to loopback.

## Hardware

| | |
|---|---|
| Machine | NVIDIA DGX Spark (GB10 Grace Blackwell, sm_121, arm64) |
| Memory | 128 GB unified (121 GiB usable), ~273 GB/s bandwidth |
| Storage | 3.7 TB NVMe |
| OS | Ubuntu 24.04 |

Memory bandwidth, not capacity, is what limits token generation here. A sparse
MoE that activates 6B of 176B parameters is the right shape for this box; a
dense model of comparable quality would run several times slower.

## The model

| | |
|---|---|
| Model | [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) — 125B backbone + 51B n-gram embeddings + 4B MTP, 6B active |
| Checkpoint | [`nvidia/Qwen3.8-Flash-Next-NVFP4`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4) (132.7 GB, 11 shards) |
| Layout served | `-fp8hybrid` — NVFP4 experts + blockwise-fp8 side layers |
| Architecture | `qwen4exp`; 3:1 Gated DeltaNet to Qwen Sparse Attention, 512 experts (10 routed + 1 shared) |
| Context | 262,144 native, **500,000 served** via YaRN factor 4 |
| Quality | SWE-bench Pro 62.5, SWE-bench Multilingual 81.0, LiveCodeBench v6 91.9 |

The hybrid layout is produced locally by `prepare-hybrid.sh`: 1,836 side-layer
tensors converted to blockwise fp8, worst per-tensor relative error 0.035. It
buys ~20% decode speed at the same quality.

## How it fits

The PLE ("parallel lookup embedding") n-gram table is 320,001,536 rows × 160 B
= **47.7 GiB**, and a token only reads 16 rows of it. Keeping it resident wastes
almost 40% of the machine on a lookup table. The upstream recipe patches vLLM to
`mmap` it from NVMe, so it lives in the page cache rather than in the model's
memory budget.

```
125 GiB checkpoint - 47.7 GiB table = ~75 GiB resident weights
121 GiB pool - 75 GiB weights = room for a 19.5 GiB KV cache and page cache
```

Without that patch the model cannot be served on one Spark at all.

## Credit

The vLLM image and serving recipe are **not ours**. They come from:

- **[blazux/qwen3.8-Flash-DGX](https://github.com/blazux/qwen3.8-Flash-DGX)** — the
  single-Spark recipe: PLE mmap, prefix-caching block-size fix, deterministic QSA
  top-k, hybrid fp8 layout, and the `reasoning_effort` template alias. 13 patches
  over the official image.
- **[jschmied/qwen38-flash-next-gb10](https://github.com/jschmied/qwen38-flash-next-gb10)** —
  deterministic `persistent_topk` CUDA kernel (upstream `vllm#55122`) and the
  fp8 M%4 GEMM padding. Apache-2.0.
- **@Saren-Arterius** — GB10 flash-linear-attention fixes and the fp8 converter.
- Base image `vllm/vllm-openai:qwen38-flash-next`, pinned by digest.

This repo holds only **our** configuration, launchers, and two local patches.
Clone the upstream recipe separately; see [Deployment](#deployment).

## Deployment

Starting from a clean Spark with Docker and the NVIDIA container runtime.

**1. Host setup** — linger, firewall rules, Docker bridge access:

```bash
sudo bin/privileged-setup.sh <lan-cidr>
sudo bin/enable-firewall.sh <lan-cidr>      # adds the SSH rule BEFORE enabling ufw
```

`<lan-cidr>` is your local subnet. It is an argument, not a default, because this
repo is public and never records a private-network address.

`ufw status` reporting `active` from `systemctl` is **not** the same as ufw
actually enforcing. Check `sudo ufw status verbose` and look for `Status: active`.

**2. API keys** — one per consumer, plus a standby. Names and the reasoning are
in [Keys and rotation](#keys-and-rotation).

```bash
umask 077
mkdir -p ~/ai-stack/secrets && chmod 700 ~/ai-stack/secrets
cp secrets.env.example ~/ai-stack/secrets/api-key.env
chmod 600 ~/ai-stack/secrets/api-key.env
# then, for EVERY variable in that file, paste a fresh value from:
openssl rand -hex 32
```

Every variable that `llama-swap.yaml` lists under `apiKeys` must be set and
non-empty before step 6, or llama-swap refuses to start.

**3. Upstream recipe + our patches:**

```bash
git clone https://github.com/blazux/qwen3.8-Flash-DGX.git ~/ai-stack/qwen38-flash
cd ~/ai-stack/qwen38-flash
patch -p1 < /path/to/this/repo/patches/01-serve-bind-loopback.patch
patch -p1 < /path/to/this/repo/patches/02-prepare-hybrid-repo-root.patch
docker build -t qwen38-flash-dgx .        # ~6 min, 20.7 GB image
```

**4. Weights** — 132.7 GB. **Xet is mandatory**, not optional: one shard is
53.7 GB and the Hub refuses files over 50 GB over plain HTTPS.

```bash
hf download nvidia/Qwen3.8-Flash-Next-NVFP4     # ~20 min at 108 MB/s
python3 -c "import hf_xet; print('xet ok')"     # verify BEFORE starting
```

**5. Hybrid layout** — one-time, ~10 min, needs ~13 GB more disk:

```bash
~/ai-stack/qwen38-flash/scripts/prepare-hybrid.sh
```

**6. Install our config:**

```bash
cp llama-swap.yaml ~/ai-stack/
cp bin/*.sh ~/ai-stack/bin/
cp systemd/llama-swap.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now llama-swap.service
bin/run-openwebui.sh
```

First boot loads ~75 GiB and takes **8-13 minutes**. Watch with
`docker logs -f qwen38-flash`; ready at `Application startup complete`.

## Measured performance

Benchmarked 2026-09-19 over the LAN with llama-benchy: `-fp8hybrid`, MTP=2, cold
prefix cache. Full method, tables and raw data:
**[docs/performance-assessment.md](docs/performance-assessment.md)**.

| | |
|---|---|
| Decode, single stream | **~30 tok/s** client-side (27-32 across runs), flat out to 131k context |
| Decode, aggregate | 50 tok/s at 2 streams, 70 at 4, **104 at 8** (13.7 tok/s each) |
| Prefill, cold | **~1,700-2,000 tok/s**, flat out to 133k. Upstream reports 2,500-2,800 warm |
| Cold time to first token | ~0.55 s per 1,000 uncached tokens: 1.4 s at 2k, 18 s at 35k, 72 s at 133k |
| Speculative decoding | 57% of drafts accepted on prose, 65% on real (coding) traffic; ~2.1-2.3 tokens per step |
| Prefix cache | 85% lifetime hit rate |
| Concurrency | 8 sequences run at once; llama-swap admits 10 by default (see [Known issues](#known-issues-and-tuning)) |
| KV pool | 721,212 tokens nominal; **~380k usable in practice** - usage measured at ~2x the token count |
| Model load | 13 min |

Three decode numbers exist for this box and they measure different things.
vLLM's engine-side `Avg generation throughput` reads 40-49 tok/s. A client timing
a whole short request - prefill, scheduling and all - sees ~23 tok/s, which was
the figure quoted here before. Decode alone, measured client-side after the first
token, is ~30 tok/s; that is the number to compare against other setups.

An earlier note here put prefill at "~200 tok/s observed". How that was measured
is not recorded - most likely short prompts, where fixed per-request overhead
dominates. On 2k-133k prompts benchy measured 1,670-1,990 tok/s.

## Configuration decisions

**`GPU_MEM=0.80`** — upstream's value. 0.85 drifted into swap after a day; 0.875
was OOM-killed on a long prefill.

**`unloadTimeout: 0`** in llama-swap — never unload on idle. The default 60s is
sensible for a model that reloads in 42 seconds; here it would discard a
13-minute load every time the operator steps away.

**vLLM bound to `127.0.0.1`** (patch 01) — upstream publishes on all interfaces.
vLLM has no auth, and **ufw would not have contained it**: Docker inserts rules
into the `DOCKER` chain in `nat`/`FORWARD`, consulted before ufw's `INPUT`
rules, so a published port stays LAN-reachable regardless of ufw policy.

**`ExecStopPost` removes `qwen38-flash`** — otherwise stopping llama-swap leaves
a 97 GiB container running with nothing managing it.

**`--restart=no`** applied by our launcher after `serve.sh` starts the container
with `unless-stopped`. llama-swap must be the only thing deciding residency.

**One bearer key per consumer** — so a leak on the least-trusted client can be
contained by revoking that one key. llama-swap's `apiKeys` is a flat, unnamed
list: this buys revocation, **not** attribution, per-consumer limits or least
privilege. Any change to the list costs a model reload; a standing standby key
keeps a rotation to one reload. Procedure and sources:
[Keys and rotation](#keys-and-rotation).

**Transport on `:9292` — OPEN, not decided.** Today every request, including
periodic probes from always-on clients, carries its bearer key over cleartext
HTTP on the LAN. Per-consumer keys limit what a captured key is worth (one
consumer, revocable); they do not stop the capture. Three positions, for the
operator to choose between:

| | A. Stay on LAN-only cleartext HTTP | B. TLS in llama-swap itself | C. TLS terminator / reverse proxy in front |
|---|---|---|---|
| What changes | nothing | add `-tls-cert-file` / `-tls-key-file` to the unit | new proxy on the LAN port; llama-swap moves to loopback |
| Key on the wire | readable by anyone who can observe the LAN segment: a compromised host, a rogue or shared Wi-Fi client, an ARP-spoofing device | encrypted | encrypted |
| New moving parts | none | a certificate to issue, renew and get trusted by **every** consumer | the same certificate work **plus** a proxy that every request now depends on |
| Consumer impact | none | every consumer's base URL changes scheme (`http` → `https`) at once; each must trust the CA or cert; enabling it is one restart = one ~13 min reload | same URL change; the on-box web UI reaches llama-swap over the Docker bridge, so it needs its own route (through the proxy, or a second listener) |
| Beyond encryption | — | nothing else: keys stay unnamed and equivalent | can name consumers in access logs, rate-limit per consumer, and change keys **without a model reload** (see [Keys and rotation](#keys-and-rotation)) |
| Risks specific to it | the exposure above, accepted and written down | certificate expiry takes every consumer down together | proxy must not buffer streamed responses and needs timeouts sized for prefill (a cold 133k prompt is ~72 s before the first byte); a misconfigured proxy is an outage for everyone |

Things that hold whichever is chosen: ufw already limits `:9292` to the LAN
subnet; clients that only need liveness can probe `/health` with **no key**,
which removes the most frequent key-bearing traffic from the weakest hosts today;
and a key captured under A is only as dangerous as the time until it is rotated.
What would tip the choice: whether any consumer is on Wi-Fi or a segment shared
with untrusted devices (towards B/C), whether per-consumer attribution and
limits are wanted anyway (towards C), and how much operational surface a
single-operator box should carry (towards A). Record the decision here, either
way, when it is made.

## Connecting agents

```bash
# Claude Code — /v1/messages works natively
ANTHROPIC_BASE_URL=http://<spark-ip>:9292 \
ANTHROPIC_AUTH_TOKEN=$TOKEN \
ANTHROPIC_MODEL=qwen3.8-flash-next \
claude

# OpenAI-compatible (aider, cline, continue, opencode)
OPENAI_BASE_URL=http://<spark-ip>:9292/v1
OPENAI_API_KEY=$TOKEN
# model: qwen3.8-flash-next
```

`$TOKEN` is **that consumer's own key** — never one shared with another host.
Keep it in the client's own secret store or a `0600` file, not in a shell rc
file that gets synced or committed.

All four endpoints are live: `/v1/models`, `/v1/chat/completions`,
`/v1/completions`, `/v1/messages`.

**Client settings that matter here:** run at most 8 requests at once (1-2 for an
interactive agent, 4 shared, 8 for batch); set timeouts for prefill, not decode
(~0.55 s per 1,000 uncached tokens, multiplied by however many requests are
prefilling); and keep the system prompt and tool definitions byte-stable at the
front of the prompt so the prefix cache keeps hitting. Reasoning is on by default
and costs ~30 ms a token - use `reasoning_effort: "low"` for short calls.

**`reasoning_effort: "high"` is the one to verify.** The checkpoint's chat
template accepts only `xhigh`/`medium`/`low` and returns 400 on anything else —
and `high` is exactly what Claude Code sends. Upstream's `EFFORT_ALIAS=1`
rewrites the template's effort line to map `high`/`max` → `xhigh` and
`minimal` → `low`. Confirm with:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<spark-ip>:9292/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","reasoning_effort":"high",
       "messages":[{"role":"user","content":"Say OK"}],"max_tokens":200}'
# expect 200, not 400
```

## Operations

```bash
systemctl --user status llama-swap.service
journalctl --user -u llama-swap.service -f
docker logs -f qwen38-flash
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9292/v1/models

# vLLM's own metrics, through llama-swap (KV usage, preemptions, spec-decode acceptance)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:9292/upstream/qwen3.8-flash-next/metrics | grep -E 'kv_cache_usage|preemptions_total|spec_decode'
```

`/metrics` and `/v1/models` can take over 10 s to answer while a long prefill is
running. Give health checks and monitors a generous timeout.

### Keys and rotation

Every consumer holds **its own** bearer key, so one consumer can be revoked
without touching the others. Names only — values live in
`~/ai-stack/secrets/api-key.env` on the box (`0600`) and nowhere else.

| Consumer name | Who holds it | Variable |
|---|---|---|
| `agent-<host>` | coding agents on one operator workstation | `LLM_KEY_AGENT_<HOST>` |
| `dashboard-<host>` | one always-on dashboard / kiosk client | `LLM_KEY_DASHBOARD_<HOST>` |
| `webui` | the Open WebUI container on this box | `LLM_KEY_WEBUI` |
| `standby` | **nobody** — a pre-issued spare, see below | `LLM_KEY_STANDBY` |

One key per host, never one per class shared across hosts. The variable is the
name upper-cased with `-` → `_`. Adding a host means one new variable in the
secrets file and one new line under `apiKeys` in `llama-swap.yaml`.

**What llama-swap gives you, and what it does not** (checked against its docs and
source, see [Sources](#sources-for-the-key-handling-facts)):

- `apiKeys` is a flat list of strings; any number of keys; a request is accepted
  if its key equals any entry. Accepted as `Authorization: Bearer`, `x-api-key`
  or HTTP Basic.
- Keys have **no names** inside llama-swap. It does not log, label or count
  requests per key, so "which consumer is hammering the box?" still has no
  answer from llama-swap alone. The names above exist only in our two files.
  (Upstream has an open feature request for per-key attribution.)
- **All keys are equivalent.** No per-key rate limit, concurrency limit,
  priority, or permission. `concurrencyLimit` is per model and shared by
  everyone. Any valid key can also call `/unload`, `/logs` and
  `/upstream/...` — so the least-trusted consumer's key can still unload the
  model for everybody. Per-consumer keys buy **revocation**, not least
  privilege. Upstream's own advice for anything more is a reverse proxy or API
  gateway in front.
- **Fairness between consumers is not something a key can carry.** The only
  related lever is request-level: llama-swap forwards the request body as sent,
  and its `filters.setParamsByID` can stamp body parameters per model-id alias.
  If vLLM is launched with `--scheduling-policy priority`, a body `priority`
  field could therefore be set per alias (say, an interactive alias and a batch
  alias). That is chosen by the client, not enforced per key, and it is a YAML
  change plus a launch-flag change — i.e. a model reload. Noted, not done.
- `/health` answers without a key. A client that only needs "is the box up?"
  should probe `/health` and **hold no key at all**; that takes the key off
  that host's periodic traffic entirely.

**Every change to the key list reloads the model (~13 minutes, every consumer
down).** There is no way around this with the stack as it is:

- Key values come from the process environment, which is read once, when
  llama-swap starts. A new or changed value needs a service restart.
- A config reload (`-watch-config` file change, or `SIGHUP`) does not help: it
  builds a new server and shuts the old one down, which **stops every model
  process**; the preload hook then starts the model from cold.
- A service restart stops the model too, and `ExecStopPost` removes the
  container.

llama-swap's documentation calls the add-new / move-clients / remove-old
sequence rotation "without downtime". That is true in the sense that a valid key
exists throughout; it does not account for a backend that takes 13 minutes to
come back. On this box each of those two edits is a full reload.

> **`-watch-config` is a live hazard.** The unit runs with it, so *saving*
> `llama-swap.yaml` on the box triggers a reload — and a model reload — within
> ~2 s, at a moment you did not choose. Edit the **secrets file** freely (it is
> only read at start); treat any edit to the YAML as an outage and do it with the
> service stopped.

**The standby key is what keeps a rotation to one reload instead of two.** It is
already accepted by llama-swap but deployed nowhere, so "add the new key" has
been done ahead of time and moving a consumer onto it restarts nothing.

#### Routine rotation of one consumer

The five steps of the classic procedure, and what each costs here:

| Step | Action | Cost |
|---|---|---|
| 1. add new | already done — the standby key is live | none |
| 2. deploy to consumer | give the consumer the standby value | none |
| 3. verify 200 | from the consumer | none |
| 4. remove old | promote standby in the secrets file, issue a fresh standby, restart | **~13 min, everyone** |
| 5. verify 401 | old key rejected, all others still 200 | none |

Steps 1-3 can happen any time. Step 4 is the only outage; schedule it.

```bash
# --- on the box, in ONE shell you keep open for the whole procedure ---
# Load the current keys into this shell only. Nothing is printed.
set -a; . ~/ai-stack/secrets/api-key.env; set +a
export OLD_KEY="$LLM_KEY_AGENT_HOST1"        # the key being retired (example consumer)
```

**2. Deploy.** Move the standby value to the consumer over a channel you trust
(a `0600` file over `scp`, or a password manager) — not chat, not email, not a
command-line argument. Point the consumer's `$TOKEN` at it.

**3. Verify 200 — from the consumer:**

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" http://<spark-ip>:9292/v1/models
# expect 200
```

**4. Remove the old key — the outage.** In `~/ai-stack/secrets/api-key.env`:
set the consumer's variable to the value that was the standby, and set
`LLM_KEY_STANDBY` to a fresh `openssl rand -hex 32`. The retired value is now
gone from the file. `llama-swap.yaml` is **not** touched. Then:

```bash
systemctl --user restart llama-swap.service
docker logs -f qwen38-flash          # ready at "Application startup complete", ~13 min
```

**5. Verify 401 for the old key, 200 for everyone else** — same shell as above, so
`OLD_KEY` still holds the retired value:

```bash
set -a; . ~/ai-stack/secrets/api-key.env; set +a      # pick up the new values
scripts/check-keys.sh http://127.0.0.1:9292 \
  --revoked agent-host1-old=OLD_KEY \
  agent-host1=LLM_KEY_AGENT_HOST1 dashboard-host1=LLM_KEY_DASHBOARD_HOST1 \
  webui=LLM_KEY_WEBUI standby=LLM_KEY_STANDBY
unset OLD_KEY
```

or by hand, one key at a time:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $OLD_TOKEN" http://<spark-ip>:9292/v1/models
# expect 401
```

`scripts/check-keys.sh` never prints a key and hands it to curl on stdin. The
hand-written `curl -H` form puts the key in that host's process list for the
life of the request; fine on a single-user machine, avoid it on a shared one.

#### Emergency revocation (a key has leaked)

Do steps 2-3 immediately so the affected consumer keeps working on the standby
key, then do step 4 **now** rather than at a scheduled window. The leaked key
stays valid until llama-swap goes down for that restart, and the restart costs
every consumer ~13 minutes: that is the price of containment on this stack, and
when to pay it is the operator's call. If the secrets file itself may have been
read, every key in it is suspect — replace them all in the same single restart.

#### Adding or removing a consumer

This one needs a YAML edit, so stop first and take exactly one reload:

```bash
systemctl --user stop llama-swap.service
#  1. add/remove the variable in ~/ai-stack/secrets/api-key.env
#  2. add/remove the matching line under apiKeys in ~/ai-stack/llama-swap.yaml
systemctl --user start llama-swap.service
journalctl --user -u llama-swap.service -n 20     # a missing or empty variable shows up here
```

If it cannot wait for a window, hand the new consumer the standby key (no
restart) and make it official — own variable, fresh standby — at the next one.

#### Open WebUI

`bin/run-openwebui.sh` passes `LLM_KEY_WEBUI` into the container. After rotating
it, re-run the script — and then **check it actually took**: Open WebUI stores
connection settings in its own database and, by default
(`ENABLE_PERSISTENT_CONFIG=True`), a value saved there wins over the environment
variable on later boots. If the UI shows models failing with 401 after a
rotation, update the key under Admin → Settings → Connections. Verify on the box;
not tested from this repo.

#### Getting to zero-reload key changes (not done)

Both routes move key checking, or the model's lifecycle, away from the process
that currently does both. Neither is implemented or tested here.

- **Check keys in a proxy in front of `:9292`.** Its key list reloads without
  touching llama-swap or the model, and it can also name consumers in access
  logs and rate-limit them. This is the same component as the TLS terminator in
  the open [transport decision](#configuration-decisions).
- **Run vLLM outside llama-swap's lifecycle** (its own unit, reached as a
  llama-swap `peer`). Restarting llama-swap would then cost seconds. Peer models
  are addressed as `<peer>/<model>`, so every consumer's model id would change.

#### Sources for the key-handling facts

From `github.com/mostlygeek/llama-swap` at tag **v256** (commit `6701d0d`), the
release installed on the box. File and line references are for that tag.
Re-read them after upgrading llama-swap.

| Fact | Where |
|---|---|
| `apiKeys` is `[]string`; empty entry or a space in a key is a load error | `internal/config/config.go:206`, `internal/config/load.go:289-298` |
| Any matching entry is accepted; 401 otherwise; nothing is logged per key | `internal/server/auth.go:16-41` |
| No per-key limits, accounts, roles or permissions; use env macros; unset variable fails the load | `docs/kb/guides/api-integration/api-keys-and-auth.md` |
| Env macros read the process environment (`os.LookupEnv`) | `internal/config/macros.go:475-496` |
| Reload = build new server, shut down old one | `llama-swap.go:306-390` |
| Server shutdown stops every model process | `internal/server/server.go:502-536`, `internal/router/base.go:278-306` |
| `/health` is outside the auth chain; `/unload`, `/logs`, `/upstream` are inside it | `internal/server/server.go:336-375` |
| Request filters: `stripParams`, `setParams`, `setParamsByID` (per model / alias, never per key) | `docs/config.example.yaml:353-395` |
| Introduced: `apiKeys` v179 (#436); env macros in `apiKeys` v184 (#467); macros in comments no longer expanded v188 (#496); `SIGHUP` reload v205 (#685) | `git tag --contains` on those commits |
| Open upstream requests: per-key permissions #971, per-key attribution #972, keys from a file #1009 | upstream issue tracker |
| Open WebUI persistent config precedence | `open-webui/docs`, `docs/reference/env-configuration.mdx` |

## Known issues and tuning

**A long prefill starves everyone else's decode.** While one request prefills a
long prompt, requests that are already generating drop from ~30 tok/s to
**1-6 tok/s** until it finishes - over a minute for a 131k prompt. Harmless with
one user; with several agents sharing the box, one cold 100k prompt stalls all of
them. The knob to test is `--max-num-batched-tokens` in the recipe's `serve.sh`
(smaller = more decode steps between prefill chunks). Untested here.

**Concurrency limits were mismatched.** vLLM runs 8 sequences at once (inferred
from queueing: at 10 in flight, exactly 8 start within ~1 s and 2 wait 20-40 s
for a slot) while llama-swap's default `concurrencyLimit` is 10, so requests 9
and 10 were accepted and then stalled silently. `llama-swap.yaml` in this repo
now sets `concurrencyLimit: 8` so the 9th request gets an immediate, retryable
429. Confirm the real `--max-num-seqs` in `serve.sh` and keep the two equal.

**KV usage runs ~2x the token count.** Two 133k-token requests filled 69.5% of
the pool; the ratio held at every load level tested. Cause not determined
(per-request DeltaNet state, block alignment, or blocks retained between runs).
Plan on ~380k tokens of context in flight, not 721k.

**Page cache starvation.** With `GPU_MEM=0.80` the box runs at ~114 GiB used and
only ~3 GiB of page cache for a 47.7 GiB mmap'd table, so PLE gathers cost
4.7-9.3 ms per op against a ~25 ms decode step. The KV pool holds 721k tokens for
what is effectively a single user. Lowering `GPU_MEM` to ~0.72 and `CTX` to the
native 262,144 would trade unused KV for page cache. Untested here - and check
it against the 2x KV finding above first: 0.72 would cut the 19.5 GiB KV pool
roughly in half, and if usage really is ~2x the token count, the remainder could
not hold even one full 262k-token request.

**Swap sits at ~5.4 GiB** and is stable — sampled flat, not climbing. Distinct
from the runaway pattern described below.

## What was tried and rejected

**SGLang** (`lmsysorg/sglang:spark`, NVIDIA/LMSYS recipe) — hangs indefinitely
after loading safetensors shards, before KV allocation. Exhausted 121 GiB and all
16 GiB of swap, twice, at default `mem-fraction` and at 0.75. Stalls at the
identical point both times, so mem-fraction is not the lever.
[`sgl-project/sglang#13382`](https://github.com/sgl-project/sglang/issues/13382),
same hardware, unresolved.

**llama.cpp with the Ollama GGUF blob** — Ollama writes its own architecture
name (`gptoss`) into the header; upstream llama.cpp rejects it with
`unknown model architecture`.

**llama.cpp for Qwen3.8-Flash-Next** — not supported. The architecture is
`qwen4exp`; NVIDIA's llama.cpp image (commit `8e7f22b6`, built 2026-08-21) was
cut five days before the model's release and its `libllama.so` contains no such
architecture. It does carry `qwen3next`, `nemotron_h_moe` and `gpt-oss`, so
Qwen3-Coder-Next, Nemotron 3 Super and gpt-oss-120b all run on it.

**Alternatives considered** for a 121 GiB box, all of which do run on llama.cpp:

| Model | Active | Coding score | Q4 size |
|---|---|---|---|
| Laguna S 2.1 | 8B | SWE-Pro 59.4 | 73 GB |
| Qwen3-Coder-Next | 3B | SWE-Verified 70.6 | 50 GB |
| Nemotron 3 Super 120B | 12B | SWE-Multilingual 45.8 | 65 GB |
| gpt-oss-120b | 5.1B | SWE-Multilingual 30.8 | 63 GB |

`examples/` keeps the previous two-model llama.cpp setup (gpt-oss-120b + Muse
Glimmer behind an exclusive llama-swap group) for reference.

## Layout

```
llama-swap.yaml                  Qwen3.8 only, preloaded, never unloaded
bin/run-qwen38.sh                wrapper over upstream serve.sh for llama-swap
bin/run-openwebui.sh             Open WebUI pointed at llama-swap
bin/privileged-setup.sh          linger, ufw rules, Docker bridge access
bin/enable-firewall.sh           enables ufw without locking out SSH
systemd/llama-swap.service       user unit
patches/                         our two changes to the upstream recipe
docs/performance-assessment.md   benchmark results, assessment, tuning and usage advice
scripts/depth-concurrency.sh     stepped long-context x concurrency test (load test: announce it first)
scripts/check-keys.sh            read-only: each consumer key gets 200, a wrong key gets 401
scripts/scrub-paths.sh           strips home paths and private addresses from benchmark logs
AGENTS.md                        rules for working in this public repo
.gitleaks.toml, .githooks/       secret + disclosure scanning (docs/secret-scanning.md)
secrets.env.example              every variable the stack reads, names only (incl. one key per consumer)
data/endpoint/                   llama-swap and vLLM config/metrics snapshots
data/benchy/                     raw llama-benchy output for every run
examples/                        superseded gpt-oss + Muse llama.cpp config
```

Secrets live in `~/ai-stack/secrets/api-key.env` (`0600`, one key per consumer)
and are **not** in this repo.
`secrets.env.example` lists every variable the stack reads.

## Contributing / working in this repo

**Read [AGENTS.md](AGENTS.md) first** — it applies to humans and AI agents alike.
The short version: this repo is public (no token values, private-network
addresses, home paths, or details of the applications that use the endpoint);
the box is shared, so no restarts, load tests or config changes without an issue
and an announced window; issue first; numbers cite the command that produced
them; never `git add -A`.

Secret scanning runs in CI on every push and PR, and as a local pre-commit hook:

```bash
git config core.hooksPath .githooks     # once per clone; needs gitleaks installed
```

Rules, manual scans and the benchmark-log scrubber:
[docs/secret-scanning.md](docs/secret-scanning.md).
