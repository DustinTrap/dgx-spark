#!/usr/bin/env python3
"""Long-context sanity: hide one fact in ~N tokens of filler (CPython stdlib source) at
several depths and ask for it back. Also, with --over, check that a prompt longer than the
served window is refused cleanly (HTTP 400) instead of being served.

  needle.py --base URL --key-file KEY --tokens 200000 --depths 0.1,0.5,0.9 --out needle.jsonl
  needle.py --base URL --key-file KEY --over 270000

Each depth is one cold ~N-token prefill (~2 minutes at 200k on this box): announce a window.
"""
import argparse, json, os, sys, time, urllib.error, urllib.request

NEEDLE = "Note for maintainers: the release signing passphrase for this module is VIOLET-4721-HARBOR."
QUESTION = "\n\nWhat is the release signing passphrase mentioned in the notes above? Reply with the passphrase only."
CHARS_PER_TOKEN = 3.2


def filler(n_chars):
    d = os.path.dirname(os.__file__)
    out, size = [], 0
    for f in sorted(os.listdir(d)):
        if f.endswith(".py"):
            t = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
            out.append(t)
            size += len(t)
            if size >= n_chars:
                break
    return "".join(out)[:n_chars]


def ask(base, key, model, text, timeout):
    body = {"model": model, "messages": [{"role": "user", "content": text}], "max_tokens": 64,
            "chat_template_kwargs": {"enable_thinking": False}, "temperature": 0}
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        return 200, resp["choices"][0]["message"].get("content") or "", resp["usage"]["prompt_tokens"], round(time.time() - t0, 1)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:300], None, round(time.time() - t0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--model", default="qwen3.8-flash-next-batch")
    ap.add_argument("--tokens", type=int, default=200000)
    ap.add_argument("--depths", default="0.1,0.5,0.9")
    ap.add_argument("--over", type=int, help="only send one prompt of about this many tokens and expect a 400")
    ap.add_argument("--out")
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args()
    key = open(os.path.expanduser(a.key_file)).read().strip()
    if a.over:
        code, text, _, secs = ask(a.base, key, a.model, filler(int(a.over * CHARS_PER_TOKEN)) + QUESTION, a.timeout)
        print(json.dumps({"over": a.over, "status": code, "seconds": secs, "body": text[:200]}))
        sys.exit(0 if code == 400 else 1)
    hay = filler(int(a.tokens * CHARS_PER_TOKEN))
    results = []
    for depth in (float(x) for x in a.depths.split(",")):
        cut = hay.rfind("\n", 0, int(len(hay) * depth)) + 1
        code, text, ptoks, secs = ask(a.base, key, a.model, hay[:cut] + "# " + NEEDLE + "\n" + hay[cut:] + QUESTION, a.timeout)
        res = {"depth": depth, "status": code, "prompt_tokens": ptoks, "seconds": secs,
               "found": "VIOLET-4721-HARBOR" in text, "answer": text[:120]}
        results.append(res)
        print(json.dumps(res), file=sys.stderr)
    if a.out:
        with open(a.out, "w") as f:
            for r in results:
                f.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
