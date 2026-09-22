#!/usr/bin/env python3
"""Spike 5b: VictoriaLogs HA without replication in the storage: two independent single-node instances fed by vlagent
(disk buffer per remote), reads through vmauth first_available. Measures catch-up after a node outage, read failover,
snapshot backup and restore into a new node. Usage: ha_test.py DATA.ndjson WORKDIR"""
import json, os, subprocess, sys, threading, time, urllib.parse, urllib.request

data, work = sys.argv[1], os.path.realpath(sys.argv[2])
UID = f"{os.getuid()}:{os.getgid()}"
NET = "lsn"
IMG = "victoriametrics/victoria-logs:latest"
def sh(*a, check=True): return subprocess.run(a, check=check, capture_output=True, text=True).stdout.strip()
def http(method, url, body=None, headers=None, timeout=60):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r: return r.read()
def count(port):
    return int(json.loads(http("POST", f"http://127.0.0.1:{port}/select/logsql/query", urllib.parse.urlencode({"query": "* | stats count() c"}).encode()).splitlines()[0])["c"])
def wait_up(port, path="/health"):
    for _ in range(100):
        try: http("GET", f"http://127.0.0.1:{port}{path}"); return
        except Exception: time.sleep(0.2)
    raise SystemExit(f"port {port} did not come up")
def vl(name, port, d):
    os.makedirs(d, exist_ok=True)
    sh("docker", "rm", "-f", name, check=False)
    sh("docker", "run", "-d", "--name", name, "--network", NET, "--user", UID, "-p", f"{port}:9428", "-v", f"{d}:/data", IMG,
       "-storageDataPath=/data", "-retentionPeriod=10y")
    wait_up(port)

for c in ("vlA", "vlB", "vlC", "vla", "vmauth"): sh("docker", "rm", "-f", c, check=False)
sh("docker", "network", "rm", NET, check=False); sh("docker", "network", "create", NET)
dA, dB, dC = (os.path.join(work, x) for x in ("A", "B", "C"))
sh("rm", "-rf", dA, dB, dC, os.path.join(work, "agent"))
vl("vlA", 9428, dA); vl("vlB", 9438, dB)
os.makedirs(os.path.join(work, "agent"), exist_ok=True)
sh("docker", "run", "-d", "--name", "vla", "--network", NET, "--user", UID, "-p", "9429:9429", "-v", f"{work}/agent:/agent", "victoriametrics/vlagent:v1.52.0",
   "-remoteWrite.url=http://vlA:9428/internal/insert", "-remoteWrite.url=http://vlB:9428/internal/insert",
   "-remoteWrite.tmpDataPath=/agent", "-remoteWrite.maxDiskUsagePerURL=10GiB")
wait_up(9429)
open(os.path.join(work, "vmauth.yml"), "w").write("""unauthorized_user:
  url_prefix: ["http://vlA:9428", "http://vlB:9428"]
  load_balancing_policy: first_available
  retry_status_codes: [502, 503]
""")
sh("docker", "run", "-d", "--name", "vmauth", "--network", NET, "-p", "8427:8427", "-v", f"{work}/vmauth.yml:/c.yml", "victoriametrics/vmauth:latest", "-auth.config=/c.yml")
wait_up(8427, "/health")

def batches(lo, hi, size=20000):
    """lines [lo,hi) of DATA as jsonline bodies"""
    with open(data) as f:
        b = []
        for i, line in enumerate(f):
            if i < lo: continue
            if i >= hi: break
            o = json.loads(line)
            b.append(json.dumps({"_msg": o["msg"], "_time": o["ts_ms"], "job": o["job"], "ln": o["ln"]}))
            if len(b) == size: yield ("\n".join(b) + "\n").encode(); b = []
        if b: yield ("\n".join(b) + "\n").encode()
def push(lo, hi):
    for b in batches(lo, hi):
        http("POST", "http://127.0.0.1:9429/insert/jsonline?_stream_fields=job&_msg_field=_msg&_time_field=_time", b, {"Content-Type": "application/x-ndjson"})
def settle(target, ports=(9428, 9438), limit=300):
    t = time.time()
    while time.time() - t < limit:
        try:
            cs = [count(p) for p in ports]
            if all(c == target for c in cs): return time.time() - t, cs
        except Exception: pass
        time.sleep(0.5)
    return None, [count(p) for p in ports if True]

N = 2_000_000
t = time.time(); push(0, N); print(f"phase 1: {N} lines through vlagent in {time.time()-t:.0f} s")
dt, cs = settle(N); print(f"  both nodes equal after +{dt:.1f} s: {cs}")

# phase 2: node B down while 2M more lines arrive, then back
sh("docker", "stop", "-t", "2", "vlB")
t = time.time(); push(N, 2 * N); print(f"phase 2: {N} lines pushed while vlB is down in {time.time()-t:.0f} s; vlA count {count(9428)}")
sh("docker", "start", "vlB"); t0 = time.time(); wait_up(9438)
dt, cs = settle(2 * N); print(f"  vlB back up; catch-up to equal counts: {'%.1f s' % dt if dt else 'NOT reached'} {cs} (expected {2*N})")
print("  agent buffer on disk after catch-up:", sh("du", "-sh", os.path.join(work, "agent")).split()[0])

# phase 3: read failover through vmauth
def probe(stop, res):
    ok_prev = True; t_fail = None
    while not stop.is_set():
        try:
            http("POST", "http://127.0.0.1:8427/select/logsql/query", b"query=*+%7C+limit+1", timeout=3); ok = True
        except Exception: ok = False
        now = time.time()
        if not ok and t_fail is None: t_fail = now
        if ok and t_fail is not None: res.append(now - t_fail); t_fail = None
        time.sleep(0.05)
stop = threading.Event(); res = []
th = threading.Thread(target=probe, args=(stop, res)); th.start(); time.sleep(2)
sh("docker", "kill", "vlA"); time.sleep(5); stop.set(); th.join()
try: c = int(json.loads(http("POST", "http://127.0.0.1:8427/select/logsql/query", urllib.parse.urlencode({"query": "* | stats count() c"}).encode()).splitlines()[0])["c"])
except Exception as e: c = f"failed: {e}"
print(f"phase 3: vlA killed; reads through vmauth failed for {[round(x,2) for x in res]} s; count via vmauth now {c}")

# phase 4: A lost its disk. Write pause of the agent, snapshot of B, copy into A, clear A's queue in the agent, resume.
t_all = time.time()
sh("docker", "stop", "-t", "2", "vla")
t = time.time(); snap = json.loads(http("POST", "http://127.0.0.1:9438/internal/partition/snapshot/create?partition_prefix=2026"))
snaps = snap if isinstance(snap, list) else json.loads(http("POST", "http://127.0.0.1:9438/internal/partition/snapshot/list"))
print(f"phase 4: snapshot of B {time.time()-t:.2f} s: {len(snaps)} partition snapshot(s)")
sh("docker", "rm", "-f", "vlA"); sh("rm", "-rf", dA); os.makedirs(dA + "/partitions")
t = time.time()
for sp in snaps:   # /data/partitions/YYYYMMDD/snapshots/NAME -> A/partitions/YYYYMMDD
    part = sp.split("/")[3]; host = os.path.join(dB, "partitions", part, "snapshots", os.path.basename(sp))
    sh("cp", "-a", host, os.path.join(dA, "partitions", part))
print(f"  copy into A: {time.time()-t:.2f} s, {sh('du','-sh',dA).split()[0]}")
sh("rm", "-rf", os.path.join(work, "agent")); os.makedirs(os.path.join(work, "agent"))
vl("vlA", 9428, dA); print(f"  A restarted, count {count(9428)} (B {count(9438)})")
sh("docker", "start", "vla"); wait_up(9429)
print(f"  write pause total: {time.time()-t_all:.1f} s")
t = time.time(); push(2 * N, 2 * N + 200000)
dt, cs = settle(2 * N + 200000); print(f"  after resume and 200k new lines: equal counts {cs} in +{dt}")
# a window query gives identical lines on both nodes
def win(port):
    q = urllib.parse.urlencode({"query": '{job="job-2"} | sort by (_time) | limit 200', "start": "1789920000.100", "end": "1789920000.400"})
    return http("POST", f"http://127.0.0.1:{port}/select/logsql/query", q.encode())
print("  identical window on A and B:", win(9428) == win(9438), len(win(9428).splitlines()))
