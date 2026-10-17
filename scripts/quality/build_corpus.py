#!/usr/bin/env python3
"""Build a fixed NLL corpus from local, public text: CPython's standard library sources
(the interpreter running this script) plus this repo's own docs and scripts.

Writes corpus.jsonl ({"id", "text"}) and a manifest (id, bucket, sources, sha256) so a later
run can prove it scored the same text. The corpus itself is not committed: rebuild it on
the same machine with the same Python, or check the manifest hashes.

Buckets are by approximate token count (code runs ~3.2 characters per token here):
  short 1-4k, medium 4-16k, long 16-64k (long docs are several stdlib files concatenated).

  build_corpus.py --out corpus.jsonl --manifest corpus-manifest.json
"""
import argparse, hashlib, json, os, sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHARS_PER_TOKEN = 3.2
BUCKETS = {"short": (1_200, 4_000, 20), "medium": (4_500, 15_000, 16), "long": (18_000, 60_000, 6)}


def chars(lo_tok, hi_tok):
    return int(lo_tok * CHARS_PER_TOKEN), int(hi_tok * CHARS_PER_TOKEN)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--manifest", required=True)
    a = ap.parse_args()
    stdlib = os.path.dirname(os.__file__)
    files = sorted(f for f in os.listdir(stdlib) if f.endswith(".py"))
    texts = [(f"stdlib/{f}", open(os.path.join(stdlib, f), encoding="utf-8", errors="replace").read()) for f in files]
    own = ["README.md", "docs/performance-assessment.md", "docs/mixed-workload-plan.md", "docs/secret-scanning.md",
           "AGENTS.md", "examples/opencode/README.md", "scripts/mixed-workload.sh", "scripts/depth-concurrency.sh",
           "scripts/wait-for-slot.sh", "bin/run-qwen38.sh", "llama-swap.yaml"]
    texts += [(f"repo/{p}", open(os.path.join(REPO, p), encoding="utf-8").read()) for p in own if os.path.exists(os.path.join(REPO, p))]

    docs, used = [], set()
    # repo prose and scripts first, so the corpus is not all Python
    for bucket in ("short", "medium"):
        lo, hi = chars(*BUCKETS[bucket][:2])
        for src, t in texts:
            if src.startswith("repo/") and lo <= len(t) <= hi and src not in used:
                docs.append((bucket, [src], t)); used.add(src)
    for bucket in ("short", "medium"):
        lo, hi, n = BUCKETS[bucket]
        lo, hi = chars(lo, hi)
        have = sum(1 for d in docs if d[0] == bucket)
        for src, t in texts:
            if have >= n:
                break
            if src.startswith("stdlib/") and lo <= len(t) <= hi and src not in used:
                docs.append((bucket, [src], t)); used.add(src); have += 1
    lo, hi, n = BUCKETS["long"]
    lo, hi = chars(lo, hi)
    targets = [lo + (hi - lo) * i // max(1, n - 1) for i in range(n)]
    pool = [(s, t) for s, t in texts if s.startswith("stdlib/") and s not in used and len(t) > 20_000]
    for target in targets:
        srcs, parts, size = [], [], 0
        while pool and size < target:
            s, t = pool.pop(0)
            srcs.append(s); parts.append(f"# ===== {s} =====\n{t}"); size += len(t)
        if size >= lo:
            docs.append(("long", srcs, "\n\n".join(parts)))

    manifest = {"python": sys.version.split()[0], "docs": []}
    with open(a.out, "w") as out:
        for i, (bucket, srcs, t) in enumerate(docs):
            did = f"{bucket}-{i:02d}"
            out.write(json.dumps({"id": did, "text": t}) + "\n")
            manifest["docs"].append({"id": did, "bucket": bucket, "sources": srcs, "chars": len(t),
                                     "sha256": hashlib.sha256(t.encode()).hexdigest()})
    json.dump(manifest, open(a.manifest, "w"), indent=1)
    for b in BUCKETS:
        print(b, sum(1 for d in docs if d[0] == b), "docs", file=sys.stderr)


if __name__ == "__main__":
    main()
