#!/usr/bin/env python3
"""HumanEval pass@1 against the endpoint, with the generated code run in a network-less
container (podman or docker, image python:3.12-slim) - never on the host.

  humaneval.py gen  --base URL --key-file KEY --data HumanEval.jsonl --out he-before.jsonl
  humaneval.py exec --data HumanEval.jsonl --gen he-before.jsonl --out he-before-results.json

Generation runs with thinking on at reasoning_effort "low" and Qwen's thinking-mode sampling
(T=1.0, top_p 0.95, top_k 20), max_tokens 8192, so a run takes tens of minutes, not hours.
Get the data from https://github.com/openai/human-eval (data/HumanEval.jsonl.gz).
"""
import argparse, concurrent.futures as cf, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request

PROMPT = ("Complete the following Python function. Reply with the complete function, including the signature "
          "and any imports it needs, in one ```python code block.\n\n```python\n{prompt}```")

RUNNER = r'''
import json, os, subprocess, sys
res = {}
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    try:
        p = subprocess.run([sys.executable, os.path.join(d, f)], capture_output=True, timeout=15, cwd="/tmp")
        res[f[:-3]] = p.returncode == 0
    except subprocess.TimeoutExpired:
        res[f[:-3]] = False
print(json.dumps(res))
'''


def gen_one(base, key, model, prob, timeout):
    body = {"model": model, "messages": [{"role": "user", "content": PROMPT.format(prompt=prob["prompt"])}],
            "max_tokens": 8192, "reasoning_effort": "low", "chat_template_kwargs": {"enable_thinking": True},
            "temperature": 1.0, "top_p": 0.95, "top_k": 20}
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        c = resp["choices"][0]
        return {"task_id": prob["task_id"], "content": c["message"].get("content") or "", "finish": c["finish_reason"],
                "completion_tokens": resp["usage"]["completion_tokens"], "seconds": round(time.time() - t0, 1)}
    except Exception as e:
        return {"task_id": prob["task_id"], "content": "", "finish": "error", "error": str(e)[:200],
                "completion_tokens": 0, "seconds": round(time.time() - t0, 1)}


def extract(content, prob):
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", content, re.S)
    code = blocks[-1] if blocks else content
    if f"def {prob['entry_point']}" not in code:
        code = prob["prompt"] + code
    return code


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--base", required=True)
    g.add_argument("--key-file", required=True)
    g.add_argument("--model", default="qwen3.8-flash-next-batch")
    g.add_argument("--data", required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--concurrency", type=int, default=4)
    g.add_argument("--timeout", type=int, default=1800)
    x = sub.add_parser("exec")
    x.add_argument("--data", required=True)
    x.add_argument("--gen", required=True)
    x.add_argument("--out", required=True)
    x.add_argument("--engine", default=shutil.which("podman") and "podman" or "docker")
    a = ap.parse_args()
    probs = [json.loads(l) for l in open(a.data)]

    if a.cmd == "gen":
        key = open(os.path.expanduser(a.key_file)).read().strip()
        done = {json.loads(l)["task_id"] for l in open(a.out)} if os.path.exists(a.out) else set()
        todo = [p for p in probs if p["task_id"] not in done]
        with cf.ThreadPoolExecutor(a.concurrency) as ex, open(a.out, "a") as out:
            for i, res in enumerate(ex.map(lambda p: gen_one(a.base, key, a.model, p, a.timeout), todo)):
                out.write(json.dumps(res) + "\n")
                out.flush()
                if (i + 1) % 20 == 0:
                    print(f"{i + 1 + len(done)}/{len(probs)}", file=sys.stderr)
        return

    gens = {json.loads(l)["task_id"]: json.loads(l) for l in open(a.gen)}
    work = tempfile.mkdtemp(prefix="he-")
    progs = os.path.join(work, "progs")
    os.mkdir(progs)
    for p in probs:
        g = gens.get(p["task_id"])
        if not g:
            continue
        prog = extract(g["content"], p) + "\n\n" + p["test"] + f"\n\ncheck({p['entry_point']})\n"
        open(os.path.join(progs, p["task_id"].replace("/", "_") + ".py"), "w").write(prog)
    open(os.path.join(work, "runner.py"), "w").write(RUNNER)
    out = subprocess.run([a.engine, "run", "--rm", "--network", "none", "--memory", "768m", "--pids-limit", "256",
                          "-v", f"{work}:/w:ro", "python:3.12-slim", "python", "/w/runner.py", "/w/progs"],
                         capture_output=True, text=True, timeout=3600)
    if out.returncode != 0:
        sys.exit(out.stderr[-2000:])
    raw = json.loads(out.stdout.strip().splitlines()[-1])
    res = {tid: raw.get(tid.replace("/", "_"), False) for tid in (p["task_id"] for p in probs)}
    meta = {tid: {"finish": gens.get(tid, {}).get("finish"), "tokens": gens.get(tid, {}).get("completion_tokens")} for tid in res}
    json.dump({"pass": res, "meta": meta}, open(a.out, "w"), indent=1)
    shutil.rmtree(work)
    print(f"pass@1 {sum(res.values())}/{len(res)}", file=sys.stderr)


if __name__ == "__main__":
    main()
