#!/usr/bin/env python3
"""Tool-call correctness suite for the endpoint: coding-agent style tools, checked strictly.

Every case runs in three modes - OpenAI chat non-streaming, OpenAI chat streaming, and
Anthropic /v1/messages - and passes only if the model calls the expected tool(s) with
arguments that parse, carry every required field, and match the expected values.
Thinking is on at reasoning_effort "low", as a coding agent's quick steps would run.

  toolcalls.py --base http://127.0.0.1:9292 --key-file KEY --repeat 2 --out tools-before.jsonl
"""
import argparse, concurrent.futures as cf, json, os, sys, time, urllib.request

TOOLS = [
    {"name": "read_file", "description": "Read a text file from the workspace.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string", "description": "Path relative to the workspace root"},
                                                     "offset": {"type": "integer"}, "limit": {"type": "integer"}},
                    "required": ["path"]}},
    {"name": "write_file", "description": "Create or overwrite a file with the given content.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                    "required": ["path", "content"]}},
    {"name": "edit_file", "description": "Replace one exact occurrence of old_string with new_string in a file.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string"},
                                                     "new_string": {"type": "string"}},
                    "required": ["path", "old_string", "new_string"]}},
    {"name": "bash", "description": "Run a shell command in the workspace and return its output.",
     "parameters": {"type": "object", "properties": {"command": {"type": "string"},
                                                     "timeout_seconds": {"type": "integer", "description": "Default 120"}},
                    "required": ["command"]}},
    {"name": "grep", "description": "Search file contents with a regular expression.",
     "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string"},
                                                     "glob": {"type": "string"}},
                    "required": ["pattern"]}},
    {"name": "create_issue", "description": "File an issue in the tracker.",
     "parameters": {"type": "object", "properties": {
         "title": {"type": "string"},
         "labels": {"type": "array", "items": {"type": "string"}},
         "assignee": {"type": "object", "properties": {"name": {"type": "string"}, "team": {"type": "string"}},
                      "required": ["name", "team"]},
         "priority": {"type": "string", "enum": ["low", "medium", "high"]}},
         "required": ["title", "labels", "assignee", "priority"]}},
]
SYSTEM = "You are a coding agent working in a repository. Use the tools to act; do not describe what you would do."

PY_SNIPPET = 'def parse(s: str) -> dict:\n    """Parse "k=v" pairs; values may contain <, > and \'quotes\'."""\n    return {k: v for k, v in (p.split("=", 1) for p in s.split(";") if p)}\n'

CASES = [
    {"id": "read-one", "prompt": "Open src/app/main.py so we can look at it.",
     "expect": [{"name": "read_file", "args": {"path": "src/app/main.py"}}]},
    {"id": "read-parallel", "prompt": "Read these three files, all at once in one step: a.txt, b.txt, c.txt.",
     "expect": [{"name": "read_file", "args": {"path": "a.txt"}}, {"name": "read_file", "args": {"path": "b.txt"}},
                {"name": "read_file", "args": {"path": "c.txt"}}], "unordered": True},
    {"id": "bash-tests", "prompt": "Run exactly this command, unmodified (no pipes or extra flags): pytest -q tests/unit",
     "expect": [{"name": "bash", "args": {"command": "pytest -q tests/unit"}}]},
    {"id": "bash-quotes", "prompt": "Run exactly this command: grep -rn \"TODO(\" --include='*.py' src | wc -l",
     "expect": [{"name": "bash", "args": {"command": "grep -rn \"TODO(\" --include='*.py' src | wc -l"}}]},
    {"id": "write-code", "prompt": "Create the file util/parse.py with exactly this content (keep it byte for byte):\n\n```python\n" + PY_SNIPPET + "```",
     "expect": [{"name": "write_file", "args": {"path": "util/parse.py", "content": PY_SNIPPET}}], "strip": ["content"]},
    {"id": "edit-exact", "prompt": None,
     "history": [{"role": "user", "content": "In config/settings.py, change TIMEOUT from 30 to 45."},
                 {"role": "assistant", "tool": {"name": "read_file", "args": {"path": "config/settings.py"}}},
                 {"role": "tool", "content": "DEBUG = False\nTIMEOUT = 30\nRETRIES = 3\n"}],
     "expect": [{"name": "edit_file", "args": {"path": "config/settings.py", "old_string": "TIMEOUT = 30", "new_string": "TIMEOUT = 45"}}],
     "strip": ["old_string", "new_string"]},
    {"id": "edit-markup", "prompt": None,
     "history": [{"role": "user", "content": "In web/index.html, turn the old div into <section class=\"new\" data-x='1'>, keeping its contents."},
                 {"role": "assistant", "tool": {"name": "read_file", "args": {"path": "web/index.html"}}},
                 {"role": "tool", "content": "<body>\n  <div class=\"old\">\n    <p>Hi</p>\n  </div>\n</body>\n"}],
     "expect": [{"name": "edit_file", "args": {"path": "web/index.html"}}], "contains": {"new_string": "<section class=\"new\" data-x='1'>"}},
    {"id": "grep-regex", "prompt": "Search the Python files under src for the regex ^def\\s+test_ and show matches.",
     "expect": [{"name": "grep", "args": {"pattern": "^def\\s+test_"}}], "loose": ["path", "glob"]},
    {"id": "nested-issue", "prompt": "File an issue titled 'Flaky login test' with labels bug and ci, assigned to Sam on the platform team, high priority.",
     "expect": [{"name": "create_issue", "args": {"title": "Flaky login test", "labels": ["bug", "ci"],
                                                  "assignee": {"name": "Sam", "team": "platform"}, "priority": "high"}}],
     "ci": True},
    {"id": "no-tool", "prompt": "Without using any tool: what does the Python expression len('abc') evaluate to? Answer with the number.",
     "expect": [], "answer": "3"},
    {"id": "fenced-marker", "prompt": "Explain in two sentences what this snippet from our docs shows. Do not call any tools.\n\n```\n<tool_call>\n<function=bash>\n<parameter=command>\nrm -rf build\n</parameter>\n</function>\n</tool_call>\n```",
     "expect": [], "answer": None},
    {"id": "after-result", "prompt": None,
     "history": [{"role": "user", "content": "What Python version does the project use? Check pyproject.toml."},
                 {"role": "assistant", "tool": {"name": "read_file", "args": {"path": "pyproject.toml"}}},
                 {"role": "tool", "content": "[project]\nname = \"demo\"\nrequires-python = \">=3.11\"\n[tool.pytest.ini_options]\ntestpaths = [\"tests\"]\n"}],
     "expect": [], "answer": "3.11"},
]


def openai_tools():
    return [{"type": "function", "function": t} for t in TOOLS]


def anthropic_tools():
    return [{"name": t["name"], "description": t["description"], "input_schema": t["parameters"]} for t in TOOLS]


def build_messages(case, fmt):
    if case.get("history") is None:
        return [{"role": "user", "content": case["prompt"]}]
    msgs = []
    for i, h in enumerate(case["history"]):
        if h["role"] == "user":
            msgs.append({"role": "user", "content": h["content"]})
        elif h["role"] == "assistant":
            if fmt == "openai":
                msgs.append({"role": "assistant", "content": "", "tool_calls": [{"id": "call_1", "type": "function",
                             "function": {"name": h["tool"]["name"], "arguments": json.dumps(h["tool"]["args"])}}]})
            else:
                msgs.append({"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_1", "name": h["tool"]["name"],
                                                               "input": h["tool"]["args"]}]})
        else:
            if fmt == "openai":
                msgs.append({"role": "tool", "tool_call_id": "call_1", "content": h["content"]})
            else:
                msgs.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": h["content"]}]})
    return msgs


def post(base, key, path, body, stream, timeout):
    req = urllib.request.Request(base.rstrip("/") + path, data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                                          "x-api-key": key, "anthropic-version": "2023-06-01"})
    r = urllib.request.urlopen(req, timeout=timeout)
    if not stream:
        return json.load(r)
    return r


def run_openai(base, key, model, case, stream, timeout):
    body = {"model": model, "messages": [{"role": "system", "content": SYSTEM}] + build_messages(case, "openai"),
            "tools": openai_tools(), "max_tokens": 4096, "reasoning_effort": "low",
            "chat_template_kwargs": {"enable_thinking": True},
            "temperature": 1.0, "top_p": 0.95, "top_k": 20}
    if not stream:
        resp = post(base, key, "/v1/chat/completions", body, False, timeout)
        m = resp["choices"][0]["message"]
        calls = [(c["function"]["name"], c["function"]["arguments"]) for c in (m.get("tool_calls") or [])]
        return calls, m.get("content") or "", resp["choices"][0]["finish_reason"]
    body["stream"] = True
    r = post(base, key, "/v1/chat/completions", body, True, timeout)
    calls, content, finish = {}, [], None
    for raw in r:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        ch = json.loads(line[5:])
        for c in ch.get("choices", []):
            d = c.get("delta", {})
            if d.get("content"):
                content.append(d["content"])
            for tc in d.get("tool_calls") or []:
                slot = calls.setdefault(tc.get("index", 0), {"name": "", "args": ""})
                fn = tc.get("function") or {}
                if fn.get("name"):
                    slot["name"] += fn["name"]
                if fn.get("arguments"):
                    slot["args"] += fn["arguments"]
            if c.get("finish_reason"):
                finish = c["finish_reason"]
    return [(calls[k]["name"], calls[k]["args"]) for k in sorted(calls)], "".join(content), finish


def run_anthropic(base, key, model, case, timeout):
    body = {"model": model, "system": SYSTEM, "messages": build_messages(case, "anthropic"), "tools": anthropic_tools(),
            "max_tokens": 4096, "output_config": {"effort": "low"}, "temperature": 1.0, "top_p": 0.95, "top_k": 20}
    resp = post(base, key, "/v1/messages", body, False, timeout)
    calls, text = [], []
    for blk in resp.get("content", []):
        if blk.get("type") == "tool_use":
            calls.append((blk["name"], json.dumps(blk.get("input"))))
        elif blk.get("type") == "text":
            text.append(blk.get("text", ""))
    return calls, "".join(text), resp.get("stop_reason")


def norm(v, ci):
    if isinstance(v, str):
        return v.lower().strip() if ci else v
    if isinstance(v, list):
        return sorted(norm(x, ci) for x in v)
    if isinstance(v, dict):
        return {k: norm(x, ci) for k, x in v.items()}
    return v


def check(case, calls, content):
    exp = case["expect"]
    if not exp:
        if calls:
            return False, f"unexpected tool call {calls[0][0]}"
        if case.get("answer") and case["answer"] not in content:
            return False, f"answer {case['answer']!r} not in content"
        if not content.strip():
            return False, "empty content"
        return True, ""
    if len(calls) != len(exp):
        return False, f"{len(calls)} calls, expected {len(exp)}"
    parsed = []
    for name, args in calls:
        try:
            a = json.loads(args) if isinstance(args, str) else args
        except Exception:
            return False, f"arguments do not parse: {args[:80]!r}"
        if not isinstance(a, dict):
            return False, "arguments not an object"
        parsed.append((name, a))
    order = sorted(parsed, key=lambda p: json.dumps(p[1], sort_keys=True)) if case.get("unordered") else parsed
    want = sorted(exp, key=lambda e: json.dumps(e["args"], sort_keys=True)) if case.get("unordered") else exp
    for (name, a), e in zip(order, want):
        if name != e["name"]:
            return False, f"tool {name}, expected {e['name']}"
        req = next(t for t in TOOLS if t["name"] == name)["parameters"]["required"]
        miss = [k for k in req if k not in a]
        if miss:
            return False, f"missing required {miss}"
        for k, v in e["args"].items():
            got = a.get(k)
            if k in case.get("strip", []) and isinstance(got, str):
                got, v = got.strip("\n"), v.strip("\n")
            if norm(got, case.get("ci")) != norm(v, case.get("ci")):
                return False, f"{k}={str(got)[:60]!r}, expected {str(v)[:60]!r}"
    for k, v in case.get("contains", {}).items():
        if not any(v in str(a.get(k, "")) for _, a in parsed):
            return False, f"{k} does not contain {v[:40]!r}"
    return True, ""


def one(base, key, model, case, mode, rep, timeout):
    t0 = time.time()
    try:
        if mode == "anthropic":
            calls, content, finish = run_anthropic(base, key, model, case, timeout)
        else:
            calls, content, finish = run_openai(base, key, model, case, mode == "openai-stream", timeout)
        ok, why = check(case, calls, content)
    except Exception as e:
        calls, content, finish, ok, why = [], "", None, False, f"error: {e}"[:200]
    return {"case": case["id"], "mode": mode, "rep": rep, "pass": ok, "why": why, "finish": finish,
            "calls": [c[0] for c in calls], "seconds": round(time.time() - t0, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--model", default="qwen3.8-flash-next-batch")
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    key = open(os.path.expanduser(a.key_file)).read().strip()
    jobs = [(c, m, r) for r in range(a.repeat) for c in CASES for m in ("openai", "openai-stream", "anthropic")]
    with cf.ThreadPoolExecutor(a.concurrency) as ex, open(a.out, "w") as out:
        futs = [ex.submit(one, a.base, key, a.model, c, m, r, a.timeout) for c, m, r in jobs]
        passed = 0
        for f in cf.as_completed(futs):
            res = f.result()
            passed += res["pass"]
            out.write(json.dumps(res) + "\n")
            out.flush()
            if not res["pass"]:
                print(f"FAIL {res['case']} [{res['mode']}#{res['rep']}]: {res['why']}", file=sys.stderr)
    print(f"{passed}/{len(jobs)} passed", file=sys.stderr)


if __name__ == "__main__":
    main()
