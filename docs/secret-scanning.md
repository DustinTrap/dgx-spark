# Secret and disclosure scanning

This repository is public and configures a service that holds a bearer token.
Three layers keep tokens, private-network addresses and home paths out of it.
The rules of the road are in [`AGENTS.md`](../AGENTS.md).

## What is scanned for

[`.gitleaks.toml`](../.gitleaks.toml) extends gitleaks' built-in ruleset with:

| Rule | Catches |
|---|---|
| `private-network-ipv4` | any RFC 1918 IPv4 literal. Loopback and `0.0.0.0` do not match. Write `<spark-ip>` / `<lan-cidr>` instead |
| `stack-token-assignment` | a literal of 16+ characters assigned to `LLM_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY` or `HF_TOKEN`. References such as `$LLM_API_KEY` do not match |
| `stack-sk-token` | `sk-` followed by 32+ alphanumerics, the format `secrets.env.example` generates |
| `bearer-header-literal` | a literal token after `Authorization: Bearer` |

The private-network rule exempts the handful of commits made before it existed
(the address is already in public history; the tree was scrubbed when the rule
was added). That exemption is scoped to that one rule — secret rules still scan
every commit. Do not add to it: fix the change instead.

## 1. Local pre-commit hook

Install gitleaks 8.19 or newer ([instructions](https://github.com/gitleaks/gitleaks#installing)),
then once per clone:

```bash
git config core.hooksPath .githooks
```

[`.githooks/pre-commit`](../.githooks/pre-commit) scans the staged changes with the
same config CI uses and refuses the commit on a finding (or if gitleaks is
missing). Worktrees share the setting with their main clone.

## 2. Scanning by hand

```bash
gitleaks dir . --config .gitleaks.toml --redact                        # working tree
gitleaks git . --config .gitleaks.toml --redact --log-opts="--all"     # full history
```

Always pass `--redact` — without it a finding prints the secret into your
terminal scrollback, and from there into pasted logs.

## 3. CI

[`.github/workflows/secret-scan.yml`](../.github/workflows/secret-scan.yml) runs
gitleaks on every push and pull request with a full-history checkout. Actions
are pinned by commit SHA and the gitleaks version is pinned too. PR comments and
report artifacts are switched off; a red check is the signal.

GitHub's own secret scanning and push protection (free for public repositories)
should be enabled as well under *Settings → Code security*. It catches
provider-issued credentials; it knows nothing about this stack's self-generated
`sk-` key or about private addresses, which is why the gitleaks rules exist.

## Scrubbing benchmark logs

Benchmark tools print absolute cache paths, result paths and the endpoint URL.
`scripts/depth-concurrency.sh` pipes its logs through
[`scripts/scrub-paths.sh`](../scripts/scrub-paths.sh), which rewrites
`/Users/<name>` and `/home/<name>` to `~` and any private-network host to
`<spark-ip>`, and touches nothing else. For output captured any other way, run
it over the files before staging them:

```bash
scripts/scrub-paths.sh data/benchy/*.output.txt data/benchy/progress.jsonl
```

That exact command was the one-off used to scrub the logs committed before the
scrubber existed. It is idempotent.

## If something leaks anyway

Deleting the line is not enough — it stays in history and in forks. Rotate the
token first (rotation costs a ~13-minute model reload, so announce it; see the
README's Operations section), then clean up, and record it on an issue without
repeating the value.
