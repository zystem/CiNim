#!/usr/bin/env python3
"""LogStore candidates benchmark (spike 5b). Usage: bench.py STORE DATA.ndjson WORKDIR
STORE: vlogs | loki | quickwit | clickhouse. Runs the store in Docker with a host data dir, ingests DATA,
then measures ingest rate, disk, memory, window / search latency. One store at a time (memory is measured in isolation)."""
import json, os, random, statistics, subprocess, sys, threading, time, urllib.parse, urllib.request

store, data, work = sys.argv[1], sys.argv[2], sys.argv[3]
UID = f"{os.getuid()}:{os.getgid()}"
BATCH = 20000
LINES = int(os.environ.get("LINES", "1000000"))  # lines per job in DATA
NAME = f"lsb-{store}"
PORT = {"vlogs": 9428, "loki": 3100, "quickwit": 7280, "clickhouse": 8123}[store]
BASE = f"http://127.0.0.1:{PORT}"
ddir = os.path.join(work, store); os.makedirs(ddir, exist_ok=True)

def sh(*a, check=True):
    return subprocess.run(a, check=check, capture_output=True, text=True).stdout.strip()

def http(method, path, body=None, headers=None, timeout=600):
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} {method} {path[:80]}: {e.read()[:300]!r}") from None

def mem_mib():
    s = sh("docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", NAME).split("/")[0].strip()
    n = float(''.join(c for c in s if c in "0123456789."))
    return n * (1024 if s.endswith("GiB") else 1 if s.endswith("MiB") else 1/1024)

def disk_mib():
    return int(sh("du", "-sb", ddir).split()[0]) / 1048576

# ---- start
sh("docker", "rm", "-f", NAME, check=False)
if store == "vlogs":
    sh("docker", "run", "-d", "--name", NAME, "--user", UID, "-p", f"{PORT}:9428", "-v", f"{ddir}:/data", "victoriametrics/victoria-logs:latest",
       "-storageDataPath=/data", "-retentionPeriod=10y")
elif store == "loki":
    cfg = os.path.join(ddir, "loki.yaml"); os.makedirs(ddir + "/d", exist_ok=True)
    open(cfg, "w").write("""auth_enabled: false
server: {http_listen_port: 3100, grpc_listen_port: 9096}
common: {path_prefix: /data/d, storage: {filesystem: {chunks_directory: /data/d/chunks, rules_directory: /data/d/rules}}, replication_factor: 1, ring: {instance_addr: 127.0.0.1, kvstore: {store: inmemory}}}
schema_config: {configs: [{from: 2020-01-01, store: tsdb, object_store: filesystem, schema: v13, index: {prefix: index_, period: 24h}}]}
limits_config: {reject_old_samples: false, ingestion_rate_mb: 1000, ingestion_burst_size_mb: 1000, per_stream_rate_limit: 1000MB, per_stream_rate_limit_burst: 1000MB, max_entries_limit_per_query: 100000, max_query_length: 0, max_query_lookback: 0, retention_period: 0s, volume_enabled: true}
analytics: {reporting_enabled: false}
""")
    sh("docker", "run", "-d", "--name", NAME, "--user", UID, "-p", f"{PORT}:3100", "-v", f"{ddir}:/data", "grafana/loki:latest", "-config.file=/data/loki.yaml")
elif store == "quickwit":
    sh("docker", "run", "-d", "--name", NAME, "--user", UID, "-p", f"{PORT}:7280", "-e", "QW_DISABLE_TELEMETRY=1", "-v", f"{ddir}:/quickwit/qwdata", "quickwit/quickwit:latest", "run")
elif store == "clickhouse":
    sh("docker", "run", "-d", "--name", NAME, "--user", UID, "-p", f"{PORT}:8123", "-e", "CLICKHOUSE_SKIP_USER_SETUP=1", "-v", f"{ddir}:/var/lib/clickhouse", "clickhouse/clickhouse-server:latest")
for _ in range(120):
    try:
        http("GET", {"vlogs": "/health", "loki": "/ready", "quickwit": "/health/readyz", "clickhouse": "/ping"}[store]); break
    except Exception: time.sleep(1)
else:
    print(sh("docker", "logs", "--tail", "30", NAME)); sys.exit("did not start")
time.sleep(10 if store == "loki" else 1)   # loki ring warm-up

if store == "quickwit":
    http("POST", "/api/v1/indexes", json.dumps({"version": "0.8", "index_id": "logs",
        "doc_mapping": {"mode": "strict", "timestamp_field": "ts", "field_mappings": [
            {"name": "job", "type": "text", "tokenizer": "raw", "fast": True},
            {"name": "ln", "type": "u64", "fast": True},
            {"name": "ts", "type": "datetime", "input_formats": ["unix_timestamp"], "fast": True, "fast_precision": "milliseconds"},
            {"name": "msg", "type": "text", "tokenizer": "default", "record": "position"}]},
        "indexing_settings": {"commit_timeout_secs": 10}}).encode(), {"Content-Type": "application/json"})
elif store == "clickhouse":
    http("POST", "/", b"CREATE TABLE logs (job LowCardinality(String), ln UInt32, ts_ms UInt64, msg String) ENGINE=MergeTree ORDER BY (job, ln)")

# ---- ingest (sampling memory while it runs)
peak = [0.0]; stop = threading.Event()
def sampler():
    while not stop.is_set():
        try: peak[0] = max(peak[0], mem_mib())
        except Exception: pass
        time.sleep(3)
threading.Thread(target=sampler, daemon=True).start()

def conv(batch):
    if store == "vlogs": return "".join(json.dumps({"_msg": o["msg"], "_time": o["ts_ms"], "job": o["job"], "ln": o["ln"]}) + "\n" for o in batch).encode()
    if store == "quickwit": return "".join(json.dumps({"job": o["job"], "ln": o["ln"], "ts": o["ts_ms"] // 1000, "msg": o["msg"]}) + "\n" for o in batch).encode()
    if store == "clickhouse": return "".join(json.dumps({"job": o["job"], "ln": o["ln"], "ts_ms": o["ts_ms"], "msg": o["msg"]}) + "\n" for o in batch).encode()
    if store == "loki":
        streams = {}
        for o in batch: streams.setdefault(o["job"], []).append([str(o["ts_ms"] * 1_000_000), o["msg"], {"ln": str(o["ln"])}] if False else [str(o["ts_ms"] * 1_000_000), o["msg"]])
        return json.dumps({"streams": [{"stream": {"job": j}, "values": v} for j, v in streams.items()]}).encode()

def send(batch):
    b = conv(batch)
    if store == "vlogs": http("POST", "/insert/jsonline?_stream_fields=job&_msg_field=_msg&_time_field=_time", b, {"Content-Type": "application/x-ndjson"})
    elif store == "quickwit": http("POST", "/api/v1/logs/ingest", b, {"Content-Type": "application/x-ndjson"})
    elif store == "clickhouse": http("POST", "/?query=" + urllib.parse.quote("INSERT INTO logs (job,ln,ts_ms,msg) FORMAT JSONEachRow"), b, {"Content-Type": "text/plain"})
    elif store == "loki": http("POST", "/loki/api/v1/push", b, {"Content-Type": "application/json"})

t0 = time.time(); n = 0; batch = []; textbytes = 0
with open(data) as f:
    for line in f:
        o = json.loads(line); batch.append(o); textbytes += len(o["msg"]) + 1; n += 1
        if len(batch) == BATCH: send(batch); batch = []
if batch: send(batch)
ingest_s = time.time() - t0
print(f"ingest: {n} lines {textbytes/1048576:.0f} MiB text in {ingest_s:.0f} s = {n/ingest_s:.0f} lines/s ({textbytes/1048576/ingest_s:.1f} MiB/s)")

# ---- wait until everything is searchable
def total():
    if store == "vlogs":
        return int(json.loads(http("POST", "/select/logsql/query", urllib.parse.urlencode({"query": "* | stats count() c"}).encode()).decode().splitlines()[0])["c"])
    if store == "quickwit":
        return json.loads(http("GET", "/api/v1/logs/search?query=*&max_hits=0"))["num_hits"]
    if store == "clickhouse": return int(http("POST", "/", b"SELECT count() FROM logs"))
    if store == "loki":
        q = urllib.parse.urlencode({"query": 'sum(count_over_time({job=~".+"}[3d]))'})
        r = json.loads(http("GET", "/loki/api/v1/query?" + q))["data"]["result"]
        return int(float(r[0]["value"][1])) if r else 0
t1 = time.time()
if store == 'loki': http('POST', '/flush')   # head blocks are not counted until flushed (measured: 4% of lines invisible)
while True:
    try: c = total()
    except Exception as e: c = -1
    if c >= n: break
    if time.time() - t1 > 900: print("NOT fully searchable after 900 s:", c); break
    time.sleep(2)
print(f"searchable after +{time.time()-t1:.0f} s (count {c})")
stop.set(); time.sleep(20)
print(f"disk: {disk_mib():.0f} MiB = {disk_mib()/(textbytes/1048576):.2f}x text; memory idle {mem_mib():.0f} MiB, peak during ingest {peak[0]:.0f} MiB")

# ---- queries
r = random.Random(1)
def window(job, a, b):
    """lines a..b (inclusive) of job in order; returns the count"""
    ts_a, ts_b = 1789900000000 + int(job.split("-")[1]) * 10_000_000 + a, 1789900000000 + int(job.split("-")[1]) * 10_000_000 + b
    if store == "vlogs":
        q = f'{{job="{job}"}} | sort by (_time) | limit 500'
        p = urllib.parse.urlencode({"query": q, "start": f"{ts_a/1000:.3f}", "end": f"{(ts_b+1)/1000:.3f}"})
        return len(http("POST", "/select/logsql/query", p.encode()).splitlines())
    if store == "loki":
        p = urllib.parse.urlencode({"query": f'{{job="{job}"}}', "start": ts_a * 1_000_000, "end": (ts_b + 1) * 1_000_000, "limit": 500, "direction": "forward"})
        return sum(len(s["values"]) for s in json.loads(http("GET", "/loki/api/v1/query_range?" + p))["data"]["result"])
    if store == "quickwit":
        p = urllib.parse.urlencode({"query": f"job:{job} AND ln:[{a} TO {b}]", "max_hits": 500, "sort_by_field": "ln"})
        return len(json.loads(http("GET", "/api/v1/logs/search?" + p))["hits"])
    if store == "clickhouse":
        return len(http("POST", "/", f"SELECT msg FROM logs WHERE job='{job}' AND ln BETWEEN {a} AND {b} ORDER BY ln FORMAT TSV".encode()).splitlines())

def timeit(fn, runs):
    ms = []
    for _ in range(runs):
        t = time.time(); fn(); ms.append((time.time() - t) * 1000)
    ms.sort(); return statistics.median(ms), ms[int(len(ms) * 0.95) - 1]

for label, size in (("window 200", 200), ("window 500", 500)):
    def one():
        job = f"job-{r.randint(1,5)}"; a = r.randint(1, LINES - size); got = window(job, a, a + size - 1)
        if got != size: raise SystemExit(f"{label}: expected {size} got {got} for {job} {a}")
    p50, p95 = timeit(one, 100)
    print(f"{label}: p50 {p50:.1f} ms, p95 {p95:.1f} ms")

def search(term, job, limit=200):
    if store == "vlogs":
        return len(http("POST", "/select/logsql/query", urllib.parse.urlencode({"query": f'{{job="{job}"}} "{term}" | limit {limit}'}).encode()).splitlines())
    if store == "loki":
        p = urllib.parse.urlencode({"query": f'{{job="{job}"}} |= "{term}"', "start": 1789900000000 * 1_000_000, "end": 1789990000000 * 1_000_000, "limit": limit, "direction": "forward"})
        return sum(len(s["values"]) for s in json.loads(http("GET", "/loki/api/v1/query_range?" + p))["data"]["result"])
    if store == "quickwit":
        return len(json.loads(http("GET", "/api/v1/logs/search?" + urllib.parse.urlencode({"query": f"job:{job} AND msg:{term}", "max_hits": limit})))["hits"])
    if store == "clickhouse":
        return len(http("POST", "/", f"SELECT msg FROM logs WHERE job='{job}' AND {'msg LIKE' + repr('%'+term+'%') if '=' in term else 'hasToken(msg,'+repr(term)+')'} LIMIT {limit} FORMAT TSV".encode()).splitlines())

def count(term, job):
    if store == "vlogs": return json.loads(http("POST", "/select/logsql/query", urllib.parse.urlencode({"query": f'{{job="{job}"}} "{term}" | stats count() c'}).encode()).splitlines()[0])["c"]
    if store == "loki":
        p = urllib.parse.urlencode({"query": f'sum(count_over_time({{job="{job}"}} |= "{term}" [3d]))'})
        return json.loads(http("GET", "/loki/api/v1/query?" + p))["data"]["result"][0]["value"][1]
    if store == "quickwit": return json.loads(http("GET", "/api/v1/logs/search?" + urllib.parse.urlencode({"query": f"job:{job} AND msg:{term}", "max_hits": 0})))["num_hits"]
    if store == "clickhouse": return http("POST", "/", f"SELECT count() FROM logs WHERE job='{job}' AND hasToken(msg,'{term}')".encode()).decode().strip()

for label, fn in (("search frequent word 'timeout' first 200 hits in job", lambda: search("timeout", "job-3")),
                  ("search rare token 'hit=88696' in job", lambda: search("hit=88696" if store != "quickwit" else "88696", "job-3")),
                  ("count of frequent word 'timeout' in job (1M lines)", lambda: count("timeout", "job-3"))):
    try:
        t = time.time(); res = fn(); dt = (time.time() - t) * 1000
        t = time.time(); fn(); dt2 = (time.time() - t) * 1000
        print(f"{label}: {dt:.0f} ms cold / {dt2:.0f} ms repeat (result {res})")
    except Exception as e: print(f"{label}: FAILED {e}")
print(f"memory after queries {mem_mib():.0f} MiB")
sh("docker", "rm", "-f", NAME, check=False)
