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
            |  http://<spark-ip>:9292/v1      bearer token, LAN only
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
token, the `0.0.0.0:9292` surface every client already points at, and the
process lifecycle. vLLM itself has no authentication, which is why its port is
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
sudo bin/privileged-setup.sh
sudo bin/enable-firewall.sh      # adds the SSH rule BEFORE enabling ufw
```

`ufw status` reporting `active` from `systemctl` is **not** the same as ufw
actually enforcing. Check `sudo ufw status verbose` and look for `Status: active`.

**2. API key:**

```bash
mkdir -p ~/ai-stack/secrets
printf 'LLM_API_KEY=sk-%s\n' "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)" \
  > ~/ai-stack/secrets/api-key.env
chmod 600 ~/ai-stack/secrets/api-key.env
```

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

## Connecting agents

```bash
# Claude Code — /v1/messages works natively
ANTHROPIC_BASE_URL=http://<spark-ip>:9292 \
ANTHROPIC_AUTH_TOKEN=$LLM_API_KEY \
ANTHROPIC_MODEL=qwen3.8-flash-next \
claude

# OpenAI-compatible (aider, cline, continue, opencode)
OPENAI_BASE_URL=http://<spark-ip>:9292/v1
OPENAI_API_KEY=$LLM_API_KEY
# model: qwen3.8-flash-next
```

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
  -H "Authorization: Bearer $LLM_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next","reasoning_effort":"high",
       "messages":[{"role":"user","content":"Say OK"}],"max_tokens":200}'
# expect 200, not 400
```

## Operations

```bash
systemctl --user status llama-swap.service
journalctl --user -u llama-swap.service -f
docker logs -f qwen38-flash
curl -s -H "Authorization: Bearer $LLM_API_KEY" http://127.0.0.1:9292/v1/models

# vLLM's own metrics, through llama-swap (KV usage, preemptions, spec-decode acceptance)
curl -s -H "Authorization: Bearer $LLM_API_KEY" \
  http://127.0.0.1:9292/upstream/qwen3.8-flash-next/metrics | grep -E 'kv_cache_usage|preemptions_total|spec_decode'
```

`/metrics` and `/v1/models` can take over 10 s to answer while a long prefill is
running. Give health checks and monitors a generous timeout.

**Rotating the key** costs ~13 minutes of downtime — restarting llama-swap fires
`ExecStopPost`, which removes the container and forces a full reload. Open WebUI
must be restarted too; the old key is baked into its container environment and it
will silently 401 otherwise.

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
scripts/depth-concurrency.sh     stepped long-context x concurrency test
data/endpoint/                   llama-swap and vLLM config/metrics snapshots
data/benchy/                     raw llama-benchy output for every run
examples/                        superseded gpt-oss + Muse llama.cpp config
```

Secrets live in `~/ai-stack/secrets/api-key.env` and are **not** in this repo.
