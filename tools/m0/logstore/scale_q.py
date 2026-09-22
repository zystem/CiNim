#!/usr/bin/env python3
"""Queries against a 100M-line single VictoriaLogs (streams job x rep, see scale.sh)."""
import json, random, statistics, subprocess, time, urllib.parse, urllib.request
def q(query, **kw):
    p = urllib.parse.urlencode({"query": query, **kw})
    return urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:9428/select/logsql/query", data=p.encode()), timeout=600).read()
def mem(): return subprocess.run(["docker","stats","--no-stream","--format","{{.MemUsage}}","vlS"],capture_output=True,text=True).stdout.split("/")[0].strip()
r = random.Random(7)
def win(size):
    job, rep = r.randint(1, 5), r.randint(1, 20); a = r.randint(1, 1_000_000 - size)
    t0 = 1789900000000 + job * 10_000_000 + a
    out = q(f'{{job="job-{job}",rep="{rep}"}} | sort by (_time) | limit 500', start=f"{t0/1000:.3f}", end=f"{(t0+size)/1000:.3f}")
    assert len(out.splitlines()) == size, (job, rep, a, len(out.splitlines()))
for size in (200, 500):
    ms = []
    for _ in range(100):
        t = time.time(); win(size); ms.append((time.time() - t) * 1000)
    ms.sort(); print(f"window {size} over 100M lines: p50 {statistics.median(ms):.1f} ms, p95 {ms[94]:.1f} ms, max {ms[-1]:.1f}")
def timed(label, query, **kw):
    t = time.time(); out = q(query, **kw); a = (time.time() - t) * 1000
    t = time.time(); q(query, **kw); b = (time.time() - t) * 1000
    print(f"{label}: {a:.0f} ms cold / {b:.0f} ms repeat -> {out.decode().strip()[:80]!r}")
timed("first 200 hits 'timeout' in one job stream (1M lines)", '{job="job-3",rep="9"} "timeout" | limit 200')
timed("rare token 'hit=88696' in one job stream", '{job="job-3",rep="9"} "hit=88696" | limit 20')
timed("count 'timeout' in one job stream", '{job="job-3",rep="9"} "timeout" | stats count() c')
timed("count 'timeout' over ALL 100M lines", '"timeout" | stats count() c')
timed("rare token over ALL 100M lines", '"hit=88696" | stats count() c')
print("memory after queries", mem())
