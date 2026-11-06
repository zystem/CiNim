#!/usr/bin/env python3
"""A receiver of the webhooks of the core (D-111, docs/webhooks.md), for a person or a tool that follows runs: it prints ONE line for each event (so that a monitor can turn each line into a notification),
checks the signature when WEBHOOK_SECRET is set, and keeps the whole body as a line of JSON in WEBHOOK_LOG (default: webhooks.jsonl in the current directory).
  WEBHOOK_SECRET=<the value of the secret the webhook names> tools/test/webhook-listen.py [port]      (default port 18999; it listens on all addresses)
Add the host of this machine to the allowed hosts of the shard (the chart value webhooks.allowedHosts, CINIM_WEBHOOK_HOSTS), make a webhook (POST .../organizations/<slug>/webhooks) and ask for a ping."""
import hashlib, hmac, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("WEBHOOK_SECRET", "")
LOG = os.environ.get("WEBHOOK_LOG", "webhooks.jsonl")


def summary(event, body, sig):
    run = body.get("run", {})
    parts = [time.strftime("%H:%M:%S"), event]
    if body.get("organization"):
        parts.append(body["organization"] + ("/" + body["project"] if body.get("project") else ""))
    if run:
        parts += ["run=" + run.get("id", ""), "state=" + run.get("state", ""), "ref=" + str(run.get("ref", "")), "commit=" + str(run.get("commit", ""))[:7]]
        if run.get("link"):
            parts.append(run["link"])
    st = body.get("step")
    if st:
        parts += ["step=%s/%s" % (st.get("job_id"), st.get("step_id")), "exit=%s" % st.get("exit_code"), str(st.get("termination", ""))]
    fail = body.get("failure")
    if fail:
        parts.append("failure=%s: %s" % (fail.get("code"), str(fail.get("message", ""))[:120]))
    if sig:
        parts.append("signature=" + sig)
    return " ".join(parts)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        sig = ""
        if SECRET:
            want = "sha256=" + hmac.new(SECRET.encode(), raw, hashlib.sha256).hexdigest()
            sig = "ok" if hmac.compare_digest(want, self.headers.get("X-CiNim-Signature", "")) else "BAD"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        event = self.headers.get("X-CiNim-Event", body.get("event", "?"))
        with open(LOG, "a") as f:
            f.write(json.dumps(body, separators=(",", ":")) + "\n")
        print(summary(event, body, sig), flush=True)
        self.send_response(200 if sig != "BAD" else 401)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok\n" if sig != "BAD" else b"bad signature\n")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18999
    print("listening on :%d (signature %s, log %s)" % (port, "checked" if SECRET else "not checked", LOG), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
