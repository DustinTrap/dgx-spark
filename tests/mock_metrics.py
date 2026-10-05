#!/usr/bin/env python3
"""mock_metrics.py - stand-in for llama-swap's /upstream/<model>/metrics (issue #25).

Used by tests/test-wait-for-slot.sh. Binds 127.0.0.1 on a free port and prints
the port on the first line of stdout. Never contacts anything.

The <model> segment of the path picks the scenario:
  room      running=1 waiting=0
  busy      running=5 waiting=2
  multi     two engines (running 2+1, waiting 1+0) plus a ..._by_reason line
            of 99 that must not be counted
  nogauge   200 with unrelated metrics only
  err500    HTTP 500
  slow      answers after 4 s with the room numbers
  frees     busy for the first 2 samples, room after that
Any other model gets 404. A bearer key other than $MOCK_KEY gets 401.
"""
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = os.environ.get("MOCK_KEY", "test-key")  # env, not argv: the test checks argv for it
HITS = {}

ROOM = (
    'vllm:num_requests_running{engine="0"} 1.0\n'
    'vllm:num_requests_waiting{engine="0"} 0.0\n'
)
BUSY = (
    'vllm:num_requests_running{engine="0"} 5.0\n'
    'vllm:num_requests_waiting{engine="0"} 2.0\n'
)
MULTI = (
    "# HELP vllm:num_requests_running Number of requests in model execution batches.\n"
    'vllm:num_requests_running{engine="0"} 2.0\n'
    'vllm:num_requests_running{engine="1"} 1.0\n'
    'vllm:num_requests_waiting{engine="0"} 1.0\n'
    'vllm:num_requests_waiting{engine="1"} 0.0\n'
    'vllm:num_requests_waiting_by_reason{reason="capacity"} 99.0\n'
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=""):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the client gave up first, which is what the slow case tests

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "upstream" or parts[2] != "metrics":
            return self.reply(404, "not found")
        if self.headers.get("Authorization") != "Bearer " + KEY:
            return self.reply(401, "unauthorized")
        scenario = parts[1]
        HITS[scenario] = HITS.get(scenario, 0) + 1
        if scenario == "room":
            return self.reply(200, ROOM)
        if scenario == "busy":
            return self.reply(200, BUSY)
        if scenario == "multi":
            return self.reply(200, MULTI)
        if scenario == "nogauge":
            return self.reply(200, "process_cpu_seconds_total 3.0\n")
        if scenario == "err500":
            return self.reply(500, "internal error")
        if scenario == "slow":
            time.sleep(4)
            return self.reply(200, ROOM)
        if scenario == "frees":
            return self.reply(200, BUSY if HITS[scenario] <= 2 else ROOM)
        return self.reply(404, "no such model")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
