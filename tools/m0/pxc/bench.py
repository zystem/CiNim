#!/usr/bin/env python3
"""Spike: PXC (Percona XtraDB Cluster, Galera) vs rqlite as the shard state store (D-02 review).
Same schema and scenarios as tests/integration/trqlite.nim / ADR 0004, run against both engines through the
same script so the numbers are directly comparable. Usage:

  bench.py rqlite  http://127.0.0.1:14001                 kubectl --context admin@home -n rqlite
  bench.py pxc     mysql://root:bench-root-pw@127.0.0.1:13306/bench   "kubectl --context admin@home -n pxc"

Connections for PXC go through port-forward to the haproxy write port (3306); rqlite through port-forward to a
node (any node proxies writes to the leader). Node-kill test needs the second arg (kubectl prefix) and, for PXC,
the pod currently acting as primary is identified via @@hostname before the kill.
"""
import concurrent.futures as cf, json, os, statistics, subprocess, sys, threading, time, urllib.request

engine, dsn = sys.argv[1], sys.argv[2]
kubectl = sys.argv[3].split() if len(sys.argv) > 3 else None

if engine == "pxc":
    import pymysql
    from urllib.parse import urlparse
    u = urlparse(dsn)
    dbname = u.path.lstrip("/") or "bench"
    def conn():
        return pymysql.connect(host=u.hostname, port=u.port or 3306, user=u.username, password=u.password,
                                database=dbname, autocommit=False, connect_timeout=5)
    _boot = pymysql.connect(host=u.hostname, port=u.port or 3306, user=u.username, password=u.password, connect_timeout=5)
    _boot.cursor().execute(f"CREATE DATABASE IF NOT EXISTS {dbname}")
    _boot.close()
else:
    import http.client
    from urllib.parse import urlparse
    u = urlparse(dsn)
    _tls = threading.local()
    def _hc():
        # one persistent keep-alive connection per thread through the port-forward tunnel, like the Nim
        # HttpClient the production client uses (a fresh connection per request throttles kubectl port-forward).
        c = getattr(_tls, "c", None)
        if c is None:
            c = http.client.HTTPConnection(u.hostname, u.port, timeout=15)
            _tls.c = c
        return c
    def http_(method, path, body=None):
        for attempt in (1, 2):
            c = _hc()
            try:
                c.request(method, path, body=body, headers={"Content-Type": "application/json"} if body else {})
                r = c.getresponse()
                data = r.read()
                return json.loads(data)
            except Exception:
                try: c.close()
                except Exception: pass
                _tls.c = None
                if attempt == 2: raise
    def rq_exec(stmts, transaction=False):
        q = "?transaction" if transaction else ""
        r = http_("POST", "/db/execute" + q, json.dumps(stmts).encode())
        if r.get("error"): raise RuntimeError(r["error"])
        for res in r["results"]:
            if res.get("error"): raise RuntimeError(res["error"])
        return r
    def rq_query(stmts):
        r = http_("POST", "/db/query", json.dumps(stmts).encode())
        if r.get("error"): raise RuntimeError(r["error"])
        return r

def report(name, v): print(f"  METRIC {name} = {v}")

def setup_steps(n):
    if engine == "pxc":
        c = conn(); cur = c.cursor()
        cur.execute("DROP TABLE IF EXISTS steps")
        cur.execute("CREATE TABLE steps(id INT PRIMARY KEY, state VARCHAR(20), profile_id VARCHAR(20), "
                    "priority INT, queued_at INT, controller_id VARCHAR(40), pod_name VARCHAR(80), version INT DEFAULT 0)")
        cur.executemany("INSERT INTO steps(id,state,profile_id,priority,queued_at) VALUES (%s,'queued','p',%s,%s)",
                         [(i, i % 5, i) for i in range(1, n + 1)])
        c.commit(); cur.close(); c.close()
    else:
        rq_exec(["DROP TABLE IF EXISTS steps",
                 "CREATE TABLE steps(id INTEGER PRIMARY KEY, state TEXT, profile_id TEXT, priority INT, "
                 "queued_at INT, controller_id TEXT, pod_name TEXT, version INT DEFAULT 0)"])
        rq_exec([["INSERT INTO steps(id,state,profile_id,priority,queued_at) VALUES (?,'queued','p',?,?)", i, i % 5, i]
                 for i in range(1, n + 1)], transaction=True)

def claim_one_pxc(cur, ctrl):
    cur.execute("SELECT id FROM steps WHERE state='queued' AND profile_id='p' ORDER BY priority DESC, "
                "queued_at LIMIT 1 FOR UPDATE SKIP LOCKED")
    row = cur.fetchone()
    if row is None: return None
    cur.execute("UPDATE steps SET state='dispatched', controller_id=%s, pod_name=%s, version=version+1 "
                "WHERE id=%s", (ctrl, "pod-" + str(row[0]), row[0]))
    return row[0]

def claimer(ctrl, claimed):
    if engine == "pxc":
        c = conn(); cur = c.cursor()
        while True:
            c.begin()
            rid = claim_one_pxc(cur, ctrl)
            c.commit()
            if rid is None: break
            claimed.append(rid)
        cur.close(); c.close()
    else:
        while True:
            r = rq_exec([["UPDATE steps SET state='dispatched', controller_id=?, pod_name='pod-'||id, version=version+1 "
                          "WHERE id=(SELECT id FROM steps WHERE state='queued' AND profile_id='p' ORDER BY priority DESC, "
                          "queued_at LIMIT 1) AND state='queued' RETURNING id", ctrl]])
            vals = r["results"][0].get("values")
            if not vals: break
            claimed.append(vals[0][0])

def bench_claim(n=300, clients=8):
    setup_steps(n)
    results = [[] for _ in range(clients)]
    t0 = time.time()
    with cf.ThreadPoolExecutor(clients) as ex:
        list(ex.map(lambda i: claimer(f"ctrl{i}", results[i]), range(clients)))
    dt = time.time() - t0
    total = sum(len(r) for r in results)
    allc = set(x for r in results for x in r)
    report(f"claim_{n}_steps_{clients}_clients_s", f"{dt:.2f}")
    report(f"claim_{n}_steps_{clients}_clients_per_s", f"{n/dt:.0f}")
    assert total == n, f"expected {n} claims, got {total}"
    assert len(allc) == n, f"a step was claimed twice: {total - len(allc)} duplicate(s)"
    print(f"  OK: all {n} steps claimed exactly once")

def bench_single_write_latency(reps=200):
    if engine == "pxc":
        c = conn(); cur = c.cursor()
        cur.execute("DROP TABLE IF EXISTS ctr"); cur.execute("CREATE TABLE ctr(id INT PRIMARY KEY, n INT)")
        cur.execute("INSERT INTO ctr VALUES (1,0)"); c.commit()
    else:
        rq_exec(["DROP TABLE IF EXISTS ctr", "CREATE TABLE ctr(id INTEGER PRIMARY KEY, n INT)"])
        rq_exec([["INSERT INTO ctr VALUES (1,0)"]])
    ms = []
    for _ in range(reps):
        t = time.time()
        if engine == "pxc":
            c.begin(); cur.execute("UPDATE ctr SET n=n+1 WHERE id=1"); c.commit()
        else:
            rq_exec([["UPDATE ctr SET n=n+1 WHERE id=1"]])
        ms.append((time.time() - t) * 1000)
    if engine == "pxc": cur.close(); c.close()
    ms.sort()
    report("single_write_p50_ms", f"{statistics.median(ms):.1f}")
    report("single_write_p95_ms", f"{ms[int(len(ms)*0.95)-1]:.1f}")
    report("single_write_writes_per_s_sequential", f"{1000/statistics.median(ms):.0f}")

def bench_batch_insert(n=500):
    def reset():
        if engine == "pxc":
            c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS bi")
            cur.execute("CREATE TABLE bi(id INT PRIMARY KEY, v INT)"); c.commit()
            return c, cur
        rq_exec(["DROP TABLE IF EXISTS bi", "CREATE TABLE bi(id INTEGER PRIMARY KEY, v INT)"])
        return None, None
    c, cur = reset()
    t0 = time.time()
    if engine == "pxc":
        cur.executemany("INSERT INTO bi(id,v) VALUES (%s,%s)", [(i, i) for i in range(1, n + 1)])
        c.commit()
    else:
        rq_exec([["INSERT INTO bi(id,v) VALUES (?,?)", i, i] for i in range(1, n + 1)], transaction=True)
    dt_batch = time.time() - t0
    report(f"batch_insert_{n}_rows_one_statement_rows_per_s", f"{n/dt_batch:.0f}")
    c, cur = reset()
    t0 = time.time()
    for i in range(1, n + 1):
        if engine == "pxc":
            c.begin(); cur.execute("INSERT INTO bi(id,v) VALUES (%s,%s)", (i, i)); c.commit()
        else:
            rq_exec([["INSERT INTO bi(id,v) VALUES (?,?)", i, i]])
    dt_single = time.time() - t0
    report(f"single_insert_{n}_rows_rows_per_s", f"{n/dt_single:.0f}")
    if engine == "pxc": cur.close(); c.close()

def bench_cas_race(pairs=100):
    if engine == "pxc":
        c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS cas")
        cur.execute("CREATE TABLE cas(id INT PRIMARY KEY, version INT)")
        cur.executemany("INSERT INTO cas VALUES (%s,1)", [(i,) for i in range(1, pairs + 1)])
        c.commit(); cur.close(); c.close()
    else:
        rq_exec(["DROP TABLE IF EXISTS cas", "CREATE TABLE cas(id INTEGER PRIMARY KEY, version INT)"])
        rq_exec([["INSERT INTO cas VALUES (?,1)", i] for i in range(1, pairs + 1)], transaction=True)
    wins = [0, 0]
    _cas_tls = threading.local()
    def race(i, side):
        if engine == "pxc":
            c = getattr(_cas_tls, "c", None)
            if c is None:
                c = conn(); _cas_tls.c = c
            cur = c.cursor()
            c.begin(); cur.execute("UPDATE cas SET version=2 WHERE id=%s AND version=1", (i,)); c.commit()
            ok = cur.rowcount == 1
            cur.close()
        else:
            r = rq_exec([["UPDATE cas SET version=2 WHERE id=? AND version=1", i]])
            ok = r["results"][0].get("rows_affected", 0) == 1
        if ok: wins[side] += 1
    with cf.ThreadPoolExecutor(min(pairs * 2, 40)) as ex:
        futs = []
        for i in range(1, pairs + 1):
            futs.append(ex.submit(race, i, 0)); futs.append(ex.submit(race, i, 1))
        for f in futs: f.result()
    total_wins = wins[0] + wins[1]
    report("cas_race_pairs", pairs)
    report("cas_race_exactly_one_winner_each", "yes" if total_wins == pairs else f"NO ({total_wins}/{pairs})")

def bench_node_kill():
    assert kubectl, "node-kill test needs the kubectl prefix as argv[3]"
    if engine == "pxc":
        c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS acked")
        cur.execute("CREATE TABLE acked(id INT PRIMARY KEY)"); c.commit()
        cur.execute("SELECT @@hostname"); primary = cur.fetchone()[0]
        cur.close(); c.close()
        report("primary_before", primary)
        target_pod = primary.split(".")[0]
    else:
        rq_exec(["DROP TABLE IF EXISTS acked", "CREATE TABLE acked(id INTEGER PRIMARY KEY)"])
        nodes = http_("GET", "/nodes")
        target_pod = next(k for k, v in nodes.items() if v.get("leader"))
        report("leader_before", target_pod)

    acked = []; ack_t = {}
    killed = threading.Event(); kill_at = [0.0]
    def killer():
        time.sleep(2.0)
        subprocess.run(kubectl + ["delete", "pod", target_pod, "--grace-period=0", "--force"], capture_output=True)
        kill_at[0] = time.time(); killed.set()
    threading.Thread(target=killer, daemon=True).start()

    t0 = time.time(); i = 0; max_gap = 0.0; last_ack = 0.0
    if engine == "pxc": c = conn(); cur = c.cursor()
    while True:
        i += 1
        try:
            if engine == "pxc":
                c.begin(); cur.execute("INSERT INTO acked(id) VALUES (%s)", (i,)); c.commit()
                ok = cur.rowcount == 1
            else:
                r = rq_exec([["INSERT INTO acked(id) VALUES (?)", i]])
                ok = r["results"][0].get("rows_affected", 0) == 1
            if ok:
                acked.append(i); ack_t[i] = time.time() - t0
                if killed.is_set():
                    now = time.time()
                    if last_ack: max_gap = max(max_gap, now - last_ack)
                    last_ack = now
        except Exception:
            if engine == "pxc":
                try: c.close()
                except Exception: pass
                try:
                    c = conn(); cur = c.cursor()
                except Exception: time.sleep(0.05)
        if killed.is_set() and time.time() - kill_at[0] > 15.0: break
        if time.time() - t0 > 90.0: break
    if engine == "pxc": cur.close(); c.close()

    have = set()
    for attempt in range(30):
        try:
            if engine == "pxc":
                c = conn(); cur = c.cursor(); cur.execute("SELECT id FROM acked")
                have = set(r[0] for r in cur.fetchall()); cur.close(); c.close()
            else:
                q = rq_query([["SELECT id FROM acked"]])
                have = set(r[0] for r in (q["results"][0].get("values") or []))
            break
        except Exception:
            time.sleep(1)
    lost = [a for a in acked if a not in have]
    report("acked_writes", len(acked))
    report("lost_acked_writes", len(lost))
    report("max_gap_between_acked_writes_after_kill_s", f"{max_gap:.2f}")
    if lost: print("  LOST ids:", lost[:20])
    assert not lost, f"{len(lost)} acknowledged write(s) lost"

if __name__ == "__main__":
    which = sys.argv[4] if len(sys.argv) > 4 else "all"
    tests = {"claim": bench_claim, "latency": bench_single_write_latency, "batch": bench_batch_insert,
             "cas": bench_cas_race, "kill": bench_node_kill}
    todo = tests if which == "all" else {which: tests[which]}
    for name, fn in todo.items():
        print(f"== {engine}: {name}")
        fn()
