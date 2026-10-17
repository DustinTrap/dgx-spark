#!/usr/bin/env python3
"""Teacher-forced per-token NLL of a fixed text corpus, for A/B-ing a serving change.

Each document is sent once to /v1/completions with prompt_logprobs=0 and max_tokens=1;
the score is the mean negative log-likelihood of the document's own tokens (the first
token, which has no logprob, is skipped). Lower is better. Run the same corpus before
and after a change and compare with compare_nll.py.

Documents of 512 tokens or fewer are rejected: with MTP enabled, prompt_logprobs is
wrong for prompts that short on the V1 runner (vllm#53488).

  nll.py --base http://127.0.0.1:9292 --key-file ~/.config/opencode/llama-swap.key \
         --model qwen3.8-flash-next-batch --corpus corpus.jsonl --out nll-before.jsonl

corpus.jsonl: one {"id": ..., "text": ...} per line (see build_corpus.py).
"""
import argparse, json, math, os, sys, time, urllib.request


def score(base, key, model, text, timeout):
    body = {"model": model, "prompt": text, "max_tokens": 1, "temperature": 0,
            "prompt_logprobs": 0}
    req = urllib.request.Request(base.rstrip("/") + "/v1/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.load(r)
    plp = resp["choices"][0].get("prompt_logprobs")
    if not plp:
        raise RuntimeError("no prompt_logprobs in response")
    lps = []
    for entry in plp[1:]:
        # with prompt_logprobs=0 each entry holds exactly the prompt token: {token_id: {"logprob": x, ...}}
        if not entry or len(entry) != 1:
            raise RuntimeError("unexpected prompt_logprobs entry: %r" % (entry,))
        lps.append(next(iter(entry.values()))["logprob"])
    n = len(lps)
    return {"tokens": resp["usage"]["prompt_tokens"], "scored": n,
            "nll": -sum(lps) / n, "seconds": round(time.time() - t0, 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--model", default="qwen3.8-flash-next-batch")
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args()
    key = open(os.path.expanduser(a.key_file)).read().strip()
    done = set()
    if os.path.exists(a.out):
        done = {json.loads(l)["id"] for l in open(a.out)}
    docs = [json.loads(l) for l in open(a.corpus)]
    with open(a.out, "a") as out:
        for d in docs:
            if d["id"] in done:
                continue
            res = score(a.base, key, a.model, d["text"], a.timeout)
            if res["tokens"] <= 512:
                print(f"skip {d['id']}: {res['tokens']} tokens <= 512 (vllm#53488)", file=sys.stderr)
                continue
            res["id"] = d["id"]
            out.write(json.dumps(res) + "\n")
            out.flush()
            print(f"{d['id']}: {res['tokens']} tok  nll {res['nll']:.4f}  ppl {math.exp(res['nll']):.3f}  {res['seconds']}s",
                  file=sys.stderr)


if __name__ == "__main__":
    main()
