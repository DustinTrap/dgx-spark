#!/usr/bin/env python3
"""Paired before/after comparison for the scripts in this directory.

  compare.py nll   nll-before.jsonl nll-after.jsonl   [--manifest corpus-manifest.json]
  compare.py tools tools-before.jsonl tools-after.jsonl
  compare.py he    he-before-results.json he-after-results.json

nll: per-document NLL difference (after - before; negative = after is better), overall and
per bucket, with an exact two-sided sign test. tools/he: pass counts and an exact McNemar
test on the discordant pairs.
"""
import json, math, sys


def binom_two_sided(k, n):
    if n == 0:
        return 1.0
    p = sum(math.comb(n, i) for i in range(0, min(k, n - k) + 1)) / 2 ** n
    return min(1.0, 2 * p)


def nll(before, after, manifest=None):
    b = {json.loads(l)["id"]: json.loads(l) for l in open(before)}
    a = {json.loads(l)["id"]: json.loads(l) for l in open(after)}
    buckets = {}
    if manifest:
        buckets = {d["id"]: d["bucket"] for d in json.load(open(manifest))["docs"]}
    ids = sorted(set(a) & set(b))
    groups = {"all": ids}
    for i in ids:
        groups.setdefault(buckets.get(i, i.split("-")[0]), []).append(i)
    print(f"{'group':8} {'docs':>4} {'tokens':>8} {'NLL before':>11} {'NLL after':>10} {'delta':>9} {'rel':>7} {'better':>7} {'sign p':>7}")
    for g, members in groups.items():
        if not members:
            continue
        tok = sum(b[i]["scored"] for i in members)
        nb = sum(b[i]["nll"] * b[i]["scored"] for i in members) / tok
        na = sum(a[i]["nll"] * a[i]["scored"] for i in members) / tok
        better = sum(1 for i in members if a[i]["nll"] < b[i]["nll"])
        worse = sum(1 for i in members if a[i]["nll"] > b[i]["nll"])
        p = binom_two_sided(better, better + worse)
        print(f"{g:8} {len(members):4d} {tok:8d} {nb:11.5f} {na:10.5f} {na - nb:+9.5f} {100 * (na - nb) / nb:+6.2f}% {better:3d}/{better + worse:<3d} {p:7.3g}")


def paired(bp, ap, label):
    keys = sorted(set(bp) & set(ap))
    nb, na = sum(bp[k] for k in keys), sum(ap[k] for k in keys)
    b_only = sum(1 for k in keys if bp[k] and not ap[k])
    a_only = sum(1 for k in keys if ap[k] and not bp[k])
    print(f"{label}: before {nb}/{len(keys)}, after {na}/{len(keys)}; "
          f"pass only before {b_only}, only after {a_only}; McNemar exact p={binom_two_sided(min(b_only, a_only), b_only + a_only):.3g}")
    for k in keys:
        if bp[k] != ap[k]:
            print(f"  {'+' if ap[k] else '-'} {k}")


def tools(before, after):
    def load(p):
        return {f"{r['case']}|{r['mode']}|{r['rep']}": r["pass"] for r in map(json.loads, open(p))}
    paired(load(before), load(after), "tool calls")


def he(before, after):
    paired(json.load(open(before))["pass"], json.load(open(after))["pass"], "HumanEval pass@1")


if __name__ == "__main__":
    kind = sys.argv[1]
    if kind == "nll":
        man = sys.argv[sys.argv.index("--manifest") + 1] if "--manifest" in sys.argv else None
        nll(sys.argv[2], sys.argv[3], man)
    elif kind == "tools":
        tools(sys.argv[2], sys.argv[3])
    elif kind == "he":
        he(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
