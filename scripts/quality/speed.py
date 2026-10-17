#!/usr/bin/env python3
"""Quick single-stream speed sanity for an A/B: cold prefill and decode, client-side.

For each prompt size, sends a unique (cache-cold) prompt of CPython stdlib text, streams
256 tokens with thinking off at temperature 0, and reports prefill tok/s (prompt tokens /
time to first token) and decode tok/s (tokens after the first / time after the first).
Not a benchmark: one request per size, for "did the change move speed" only.

  speed.py --base URL --key-file KEY --sizes 2000,32000 --repeat 3
"""
import argparse, json, os, time, urllib.request, uuid

CHARS_PER_TOKEN = 3.2


def stdlib_text(n):
    d = os.path.dirname(os.__file__)
    parts, size = [], 0
    for f in sorted(os.listdir(d), reverse=True):
        if f.endswith(".py"):
            t = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
            parts.append(t); size += len(t)
            if size >= n:
                break
    return "".join(parts)[:n]


def run(base, key, model, n_tokens):
    text = f"[{uuid.uuid4()}]\n" + stdlib_text(int(n_tokens * CHARS_PER_TOKEN)) + "\n\nSummarize the code above in detail."
    body = {"model": model, "messages": [{"role": "user", "content": text}], "max_tokens": 256, "min_tokens": 256,
            "stream": True, "stream_options": {"include_usage": True}, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.time(); first = None; usage = None
    with urllib.request.urlopen(req, timeout=1800) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            ch = json.loads(line[5:])
            if ch.get("usage"):
                usage = ch["usage"]
            if first is None and any(c.get("delta", {}).get("content") for c in ch.get("choices", [])):
                first = time.time()
    end = time.time()
    gen = usage["completion_tokens"]
    return {"prompt_tokens": usage["prompt_tokens"], "ttft_s": round(first - t0, 2),
            "prefill_tps": round(usage["prompt_tokens"] / (first - t0)), "decode_tps": round((gen - 1) / (end - first), 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--model", default="qwen3.8-flash-next-batch")
    ap.add_argument("--sizes", default="2000,32000")
    ap.add_argument("--repeat", type=int, default=3)
    a = ap.parse_args()
    key = open(os.path.expanduser(a.key_file)).read().strip()
    for n in (int(x) for x in a.sizes.split(",")):
        for i in range(a.repeat):
            print(json.dumps({"size": n, "rep": i, **run(a.base, key, a.model, n)}), flush=True)


if __name__ == "__main__":
    main()
