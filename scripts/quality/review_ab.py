#!/usr/bin/env python3
"""Reviewer-variant A/B: does a review find a seeded bug?

Each case is a small, realistic diff with exactly one real defect. The request carries the
OpenCode reviewer agent's description as the system prompt and the diff as the user turn,
and is sent once per variant per repeat. A review "finds" the bug when its text matches the
case's pattern (a regex on the defect's key terms); every miss is printed so it can be
checked by hand. Variants are request-body overrides, the same shape as OpenCode variants.

  review_ab.py --base URL --key-file KEY --repeat 3 --out review.jsonl [--set hard]
"""
import argparse, concurrent.futures as cf, json, os, re, sys, time, urllib.request

SYSTEM = ("Use proactively for adversarial review, security pass, or audit of any diff, PR, or set of files. "
          "Read-only. Returns numbered findings with file:line and a verdict per finding.")

VARIANTS = {
    "nothink": {"chat_template_kwargs": {"enable_thinking": False},
                "temperature": 0.7, "top_p": 0.8, "top_k": 20, "min_p": 0, "presence_penalty": 1.0},
    "review": {"chat_template_kwargs": {"enable_thinking": True}, "reasoning_effort": "low",
               "temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0, "presence_penalty": 0},
}

CASES = [
    {"id": "pagination-off-by-one", "find": r"(skip|miss|drop|omit|exclud|lose|lost)\w*.{0,60}(first|index 0|\[0\]|element 0|item 0)|(first|index 0|\[0\]).{0,60}(skip|miss|drop|omit|exclud|never)|off.by.one|range\(1",
     "diff": '''--- a/api/paging.py
+++ b/api/paging.py
@@ -10,9 +10,11 @@ def page(items, size):
-    return [items[i:i + size] for i in range(0, len(items), size)]
+    pages = []
+    for i in range(1, len(items), size):
+        pages.append(items[i:i + size])
+    return pages
'''},
    {"id": "sql-injection", "find": r"inject|parameteri[sz]|placeholder|bind (param|variable)|unsanitized|unescaped",
     "diff": '''--- a/store/users.py
+++ b/store/users.py
@@ -21,6 +21,9 @@ class UserStore:
+    def find_by_email(self, email: str):
+        cur = self.db.cursor()
+        cur.execute(f"SELECT id, name FROM users WHERE email = '{email}'")
+        return cur.fetchone()
'''},
    {"id": "rm-unset-var", "find": r"(unset|empty|undefined).{0,80}(var|BUILD_DIR|\$)|BUILD_DIR.{0,80}(unset|empty|undefined)|rm -rf /|set -u|\$\{BUILD_DIR:\?|quot",
     "diff": '''--- a/scripts/clean.sh
+++ b/scripts/clean.sh
@@ -1,4 +1,6 @@
 #!/usr/bin/env bash
-echo "nothing to clean"
+# BUILD_DIR comes from the CI environment
+echo "cleaning $BUILD_DIR"
+rm -rf $BUILD_DIR/*
'''},
    {"id": "mutable-default", "find": r"mutable default|default (argument|arg|parameter|value).{0,60}(shared|list|persist|reuse)|shared (across|between) calls|bucket=\[\]|=\[\].{0,40}(shared|persist|mutable)",
     "diff": '''--- a/core/collect.py
+++ b/core/collect.py
@@ -3,5 +3,7 @@
-def add(item):
-    return [item]
+def add(item, bucket=[]):
+    """Append item to bucket and return it (a new list when no bucket is given)."""
+    bucket.append(item)
+    return bucket
'''},
    {"id": "always-true-or", "find": r"always (true|truthy|evaluat)|truthy|non-empty string|or \"owner\"|or 'owner'|precedence|in \(|in \[",
     "diff": '''--- a/auth/perms.py
+++ b/auth/perms.py
@@ -14,6 +14,8 @@ def can_delete(user, doc):
-    return user.role == "admin"
+    if user.role == "admin" or "owner":
+        return True
+    return doc.owner_id == user.id
'''},
    {"id": "sleep-ms-as-s", "find": r"millisecond|\bms\b.{0,60}(second|sleep)|second.{0,60}\bms\b|/ ?1000|1000x|unit",
     "diff": '''--- a/net/retry.py
+++ b/net/retry.py
@@ -5,8 +5,10 @@ import time
-def retry(fn, attempts=3):
+def retry(fn, attempts=3, backoff_ms=200):
     for n in range(attempts):
         try:
             return fn()
         except ConnectionError:
-            time.sleep(0.2)
+            # back off before the next attempt
+            time.sleep(backoff_ms * (2 ** n))
'''},
    {"id": "js-assign-in-if", "find": r"assign|= null.{0,40}(instead|rather|should)|===|==",
     "diff": '''--- a/web/session.js
+++ b/web/session.js
@@ -8,6 +8,9 @@ export function currentUser(session) {
-  return session.user;
+  if (session.user = null) {
+    return anonymousUser();
+  }
+  return session.user;
 }
'''},
    {"id": "inverted-auth", "find": r"invert|negat|backwards|reversed|logic is (flipped|wrong)|(invalid|unauthenticated|expired).{0,80}(allow|grant|proceed|through|access)|`not`|\bnot\b.{0,40}(wrong|remove|drop)",
     "diff": '''--- a/api/middleware.py
+++ b/api/middleware.py
@@ -30,7 +30,9 @@ def require_token(handler):
     def wrapped(request):
         token = request.headers.get("Authorization", "")
-        return handler(request)
+        if not verify_token(token):
+            return handler(request)
+        return Response(status=401)
     return wrapped
'''},
    {"id": "float-index", "find": r"float|//|integer division|TypeError|true division|int\(",
     "diff": '''--- a/stats/median.py
+++ b/stats/median.py
@@ -1,4 +1,8 @@
 def median(xs):
-    return statistics.median(xs)
+    s = sorted(xs)
+    mid = len(s) / 2
+    if len(s) % 2:
+        return s[mid]
+    return (s[mid - 1] + s[mid]) / 2
'''},
    {"id": "swallowed-none", "find": r"None|swallow|silenc|suppress|bare except|except Exception|hid(e|es|ing) (the )?(error|exception)|AttributeError",
     "diff": '''--- a/io/config.py
+++ b/io/config.py
@@ -9,6 +9,12 @@ def load_config(path):
-    with open(path) as f:
-        return json.load(f)
+    try:
+        with open(path) as f:
+            return json.load(f)
+    except Exception:
+        pass
+
+def timeout_for(path):
+    return load_config(path).get("timeout", 30)
'''},
]

# Subtler defects, each mixed with harmless edits, for when CASES hits a ceiling.
HARD_CASES = [
    {"id": "bsearch-infinite-loop", "find": r"infinite loop|never terminat|loops? forever|\bhangs?\b|no progress|mid \+ 1",
     "diff": """--- a/core/search.py
+++ b/core/search.py
@@ -1,12 +1,16 @@
-import bisect
+from typing import Sequence


-def first_at_least(a, x):
-    return bisect.bisect_left(a, x)
+def first_at_least(a: Sequence[int], x: int) -> int:
+    \"\"\"Index of the first element >= x in sorted a (len(a) if none).\"\"\"
+    lo, hi = 0, len(a)
+    while lo < hi:
+        mid = (lo + hi) // 2
+        if a[mid] < x:
+            lo = mid
+        else:
+            hi = mid
+    return lo
"""},
    {"id": "unanchored-email-regex", "find": r"anchor|fullmatch|\\Z|end of (the )?string|re\.match.{0,80}(prefix|beginning|start)|(prefix|beginning).{0,40}match|example\.com\.|evil|attacker",
     "diff": """--- a/accounts/validate.py
+++ b/accounts/validate.py
@@ -3,8 +3,12 @@ import re
-def is_company_email(addr):
-    return addr.endswith("@example.com")
+COMPANY = re.compile(r"[a-z0-9._%+-]+@example\\.com", re.IGNORECASE)
+
+
+def is_company_email(addr: str) -> bool:
+    \"\"\"Only staff addresses may reach the admin console.\"\"\"
+    return COMPANY.match(addr.strip()) is not None
"""},
    {"id": "path-traversal-join", "find": r"travers|\.\./|absolute path|outside (of )?(the )?(upload|base|root)|realpath|commonpath|sanitiz|escape (the )?(upload|root|directory)",
     "diff": """--- a/web/uploads.py
+++ b/web/uploads.py
@@ -10,7 +10,12 @@ UPLOAD_ROOT = "/srv/app/uploads"
 def save_upload(request):
-    name = secrets.token_hex(8)
+    # keep the user's file name so downloads look right
+    name = request.form["filename"]
     path = os.path.join(UPLOAD_ROOT, name)
+    log.info("saving upload to %s", path)
     with open(path, "wb") as f:
         f.write(request.files["file"].read())
+    return {"stored_as": name}
"""},
    {"id": "late-binding-lambda", "find": r"late.binding|closure|captur|same (value|name)|last (value|name|item|action)|lambda \w+ ?=|default argument",
     "diff": """--- a/ui/menu.py
+++ b/ui/menu.py
@@ -4,9 +4,11 @@ class Menu:
     def build(self, actions):
-        for name in actions:
-            self.add_button(name, self._handler_for(name))
+        handlers = {}
+        for name in actions:
+            handlers[name] = lambda: self.run(name)
+        for name, fn in handlers.items():
+            self.add_button(name, fn)
"""},
    {"id": "js-numeric-sort", "find": r"lexicograph|alphabetic|string (comparison|order|sort)|as strings|to strings|compare(Fn| function)|comparator|\(a, ?b\) ?=> ?[ab] ?- ?[ab]|10 (comes|sorts|before)|numeric(al)? sort|unicode|utf-16",
     "diff": """--- a/web/leaderboard.js
+++ b/web/leaderboard.js
@@ -2,6 +2,9 @@ export function topScores(players, n) {
-  return players.map(p => p.score).slice(0, n);
+  const scores = players.map(p => p.score);
+  scores.sort();
+  scores.reverse();
+  return scores.slice(0, n);
 }
"""},
    {"id": "lock-order-deadlock", "find": r"deadlock|lock order|opposite order|inconsistent order|acquire.{0,40}(order|reverse)",
     "diff": """--- a/bank/transfer.py
+++ b/bank/transfer.py
@@ -8,10 +8,20 @@ class Account:
+def transfer(src: Account, dst: Account, amount: int) -> None:
+    with src.lock:
+        with dst.lock:
+            if src.balance < amount:
+                raise InsufficientFunds(src.id)
+            src.balance -= amount
+            dst.balance += amount
+
+
+def audit_pair(a: Account, b: Account) -> int:
+    with b.lock:
+        with a.lock:
+            return a.balance + b.balance
"""},
    {"id": "offset-without-order", "find": r"ORDER BY|order by|nondeterministic|non-deterministic|unordered|undefined order|duplicate.{0,40}(page|row)|skip.{0,40}rows|stable (order|sort)",
     "diff": """--- a/store/orders.py
+++ b/store/orders.py
@@ -15,6 +15,11 @@ class OrderStore:
+    def page(self, customer_id: int, page: int, size: int = 50):
+        return self.db.fetchall(
+            "SELECT id, total, created_at FROM orders WHERE customer_id = %s LIMIT %s OFFSET %s",
+            (customer_id, size, page * size),
+        )
"""},
    {"id": "cache-key-missing-locale", "find": r"locale.{0,120}(cache|key)|(cache|key).{0,120}locale|wrong language|stale.{0,40}translat|lru_cache.{0,80}(global|current_locale)|implicit (input|dependency)",
     "diff": """--- a/i18n/render.py
+++ b/i18n/render.py
@@ -1,9 +1,13 @@
+from functools import lru_cache
 from .state import current_locale


+@lru_cache(maxsize=4096)
 def render_label(key: str) -> str:
+    # rendering is hot in the dashboard; cache it
     table = load_table(current_locale())
     return table.get(key, key)
"""},
    {"id": "float-money-equality", "find": r"float.{0,80}(precision|round|exact|equal|compar)|floating.point|Decimal|cents|rounding error|0\.1 ?\+ ?0\.2|== ?0\b.{0,40}(float|never)|isclose",
     "diff": """--- a/billing/settle.py
+++ b/billing/settle.py
@@ -20,6 +20,12 @@ def settle(invoice):
+    paid = sum(float(p.amount) for p in invoice.payments)   # amounts are strings like "19.99"
+    due = float(invoice.total)
+    if paid - due == 0:
+        invoice.mark_paid()
+    elif paid > due:
+        issue_refund(invoice, paid - due)
"""},
    {"id": "is-int-identity", "find": r"`is`|\bis\b (operator|comparison)|identity (check|comparison)|small.int|interning|SyntaxWarning|use `?==",
     "diff": """--- a/net/limits.py
+++ b/net/limits.py
@@ -6,6 +6,10 @@ def check_quota(user, used):
-    return used < user.quota
+    limit = user.quota or DEFAULT_QUOTA
+    if used is limit:
+        notify_quota_reached(user)
+        return False
+    return used < limit
"""},
]


def one(base, key, model, case, variant, rep, timeout):
    body = {"model": model, "max_tokens": 8192,
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": "Review this diff.\n\n```diff\n" + case["diff"] + "```"}]}
    body.update(VARIANTS[variant])
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        text = resp["choices"][0]["message"].get("content") or ""
        u = resp["usage"]
        res = {"found": bool(re.search(case["find"], text, re.I | re.S)), "chars": len(text),
               "completion_tokens": u["completion_tokens"],
               "reasoning_tokens": (u.get("completion_tokens_details") or {}).get("reasoning_tokens"),
               "finish": resp["choices"][0]["finish_reason"], "text": text}
    except Exception as e:
        res = {"found": False, "error": str(e)[:200], "text": ""}
    res.update({"case": case["id"], "variant": variant, "rep": rep, "seconds": round(time.time() - t0, 1)})
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--model", default="qwen3.8-flash-next-batch")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--set", choices=["easy", "hard"], default="easy")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    cases = HARD_CASES if a.set == "hard" else CASES
    key = open(os.path.expanduser(a.key_file)).read().strip()
    jobs = [(c, v, r) for r in range(a.repeat) for c in cases for v in VARIANTS]
    rows = []
    with cf.ThreadPoolExecutor(a.concurrency) as ex, open(a.out, "w") as out:
        for res in ex.map(lambda j: one(a.base, key, a.model, *j, a.timeout), jobs):
            rows.append(res)
            out.write(json.dumps(res) + "\n")
            out.flush()
    for v in VARIANTS:
        rs = [r for r in rows if r["variant"] == v]
        found = sum(r["found"] for r in rs)
        secs = sorted(r["seconds"] for r in rs)
        print(f"{v:8} found {found}/{len(rs)}  median {secs[len(secs) // 2]}s  "
              f"mean completion tokens {sum(r.get('completion_tokens', 0) for r in rs) // max(1, len(rs))}", file=sys.stderr)
    for r in rows:
        if not r["found"]:
            print(f"MISS {r['case']} [{r['variant']}#{r['rep']}]", file=sys.stderr)


if __name__ == "__main__":
    main()
