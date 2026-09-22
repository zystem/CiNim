#!/usr/bin/env python3
"""Restart time on 100M lines, live tail freshness, tenant isolation, delete API. Single VictoriaLogs at :9428 (container vlS, -delete.enable added by caller)."""
import json, subprocess, threading, time, urllib.parse, urllib.request
B = "http://127.0.0.1:9428"
def post(path, body=b"", headers=None, timeout=600):
    return urllib.request.urlopen(urllib.request.Request(B + path, data=body, headers=headers or {}), timeout=timeout).read()
def cnt(tenant=None, query="* | stats count() c"):
    h = {"AccountID": str(tenant), "ProjectID": "0"} if tenant is not None else {}
    return int(json.loads(post("/select/logsql/query", urllib.parse.urlencode({"query": query}).encode(), h).splitlines()[0])["c"])
t = time.time(); subprocess.run(["docker", "restart", "-t", "10", "vlS"], check=True, capture_output=True)
while True:
    try: post("/select/logsql/query", b"query=*+%7C+limit+1", timeout=3); break
    except Exception: time.sleep(0.1)
print(f"restart with 100M lines: first query answered after {time.time()-t:.1f} s, count {cnt()}")

# live tail: one line per 100 ms for 20 s; tail stream vs polling query; freshness = arrival time - line's own send time
sent = {}; seen_tail = {}
def tail():
    req = urllib.request.Request(B + "/select/logsql/tail", data=urllib.parse.urlencode({"query": '{job="live"}', "start_offset": "0s"}).encode())
    r = urllib.request.urlopen(req, timeout=40)
    for line in r:
        try: o = json.loads(line)
        except Exception: continue
        seen_tail.setdefault(o.get("n"), time.time())
th = threading.Thread(target=tail, daemon=True); th.start(); time.sleep(1)
for i in range(200):
    now = time.time(); sent[str(i)] = now
    post("/insert/jsonline?_stream_fields=job&_msg_field=_msg&_time_field=_time",
         (json.dumps({"_msg": f"live line {i}", "_time": f"{now:.3f}", "job": "live", "n": str(i)}) + "\n").encode(), {"Content-Type": "application/x-ndjson"})
    time.sleep(0.1)
time.sleep(3)
d = sorted(seen_tail[k] - sent[k] for k in sent if k in seen_tail)
print(f"live tail: {len(d)}/200 lines seen, delay p50 {d[len(d)//2]*1000:.0f} ms, p95 {d[int(len(d)*0.95)]*1000:.0f} ms, max {d[-1]*1000:.0f} ms")

# tenants
hdr = lambda a: {"AccountID": str(a), "ProjectID": "0", "Content-Type": "application/x-ndjson"}
for a in (11, 12):
    post("/insert/jsonline?_stream_fields=job&_msg_field=_msg&_time_field=_time", b"\n".join(json.dumps({"_msg": f"tenant {a} line {i}", "_time": f"{time.time():.3f}", "job": "j"}).encode() for i in range(1000)) + b"\n", hdr(a))
time.sleep(1.5)
print(f"tenants: 11 sees {cnt(11)}, 12 sees {cnt(12)}, default sees {cnt()} (100M + live 200 expected)")
# delete: all lines of tenant 11 (filter), measure
t = time.time(); r = post("/delete/run_task", urllib.parse.urlencode({"filter": "*"}).encode(), {"AccountID": "11", "ProjectID": "0"}); print("delete task", r.decode()[:80], f"{time.time()-t:.2f} s")
for _ in range(100):
    time.sleep(0.5)
    if cnt(11) == 0: break
print(f"after delete: tenant 11 sees {cnt(11)}, tenant 12 sees {cnt(12)}, delete finished in {time.time()-t:.1f} s")
# delete part of the big data: one job stream of one rep (1M lines)
before = cnt(); t = time.time()
post("/delete/run_task", urllib.parse.urlencode({"filter": '{job="job-2",rep="5"}'}).encode())
for _ in range(600):
    time.sleep(1)
    if cnt() <= before - 1_000_000: break
print(f"delete of one 1M-line stream inside 100M: {before} -> {cnt()} in {time.time()-t:.1f} s")
