#!/usr/bin/env python3
"""rqlite vs Percona XtraDB Cluster (Galera) vs PostgreSQL (CloudNativePG) as the shard state store (benchmark behind D-02, see A.2).
Same schema and scenarios as tests/integration/trqlite.nim / A.2, run against every engine through the
same script so the numbers are directly comparable. Run it from a Pod inside the cluster (a tunnel such as
`kubectl port-forward` distorts latencies). Usage:

  bench.py rqlite    http://rqlite.rqlite.svc:80                                          incluster:rqlite
  bench.py pxc       mysql://root:PASSWORD@pxc-haproxy.pxc.svc:3306/bench                 incluster:pxc
  bench.py postgres  postgresql://bench:PASSWORD@pgbench-cluster-rw.pgbench:5432/bench    incluster:pgbench

All tables the script creates and drops are named `bench_*`, so it is safe to run against a database that also holds platform tables.

The third argument says how the node-kill test deletes a Pod: `incluster:<namespace>` uses the Pod's service account
(it needs the right to list and delete Pods there), anything else is a kubectl command prefix, e.g. "kubectl -n pxc".
The fourth argument selects one test (claim, latency, batch, cas, kill); all by default. The victim is the rqlite leader,
the PXC pod serving @@hostname, or the PostgreSQL pod labelled cnpg.io/instanceRole=primary.

Claiming a step is measured in the form each engine allows: rqlite and PostgreSQL can do it in one statement
(`UPDATE ... WHERE id = (SELECT ... [FOR UPDATE SKIP LOCKED]) RETURNING id`); MySQL has no RETURNING, so PXC needs
SELECT ... FOR UPDATE SKIP LOCKED + UPDATE in one transaction. For PostgreSQL the three-step form is measured as well.
"""
import concurrent.futures as cf, json, os, ssl, statistics, subprocess, sys, threading, time, urllib.request
from urllib.parse import urlparse

engine, dsn = sys.argv[1], sys.argv[2]
killer_spec = sys.argv[3] if len(sys.argv) > 3 else None
SQL = engine in ("pxc", "postgres")

if engine == "postgres":
    import psycopg2, psycopg2.extras
    def conn():
        c = psycopg2.connect(dsn, connect_timeout=5)
        c.autocommit = False
        return c
    def begin(c): pass
    def insert_many(c, cur, table_cols, template, rows):
        psycopg2.extras.execute_values(cur, f"INSERT INTO {table_cols} VALUES %s", rows, template=template, page_size=max(len(rows), 1))
elif engine == "pxc":
    import pymysql
    u = urlparse(dsn)
    dbname = u.path.lstrip("/") or "bench"
    def conn():
        return pymysql.connect(host=u.hostname, port=u.port or 3306, user=u.username, password=u.password,
                                database=dbname, autocommit=False, connect_timeout=5)
    _boot = pymysql.connect(host=u.hostname, port=u.port or 3306, user=u.username, password=u.password, connect_timeout=5)
    _boot.cursor().execute(f"CREATE DATABASE IF NOT EXISTS {dbname}")
    _boot.close()
    def begin(c): c.begin()
    def insert_many(c, cur, table_cols, template, rows):
        cur.executemany(f"INSERT INTO {table_cols} VALUES {template}", rows)
else:
    import http.client
    u = urlparse(dsn)
    _tls = threading.local()
    def _hc():
        # one persistent keep-alive connection per thread, like the Nim HttpClient the production client uses
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

# ---- Kubernetes access for the node-kill test ------------------------------------------------------------------

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
def kube(method, path):
    ctx = ssl.create_default_context(cafile=SA + "/ca.crt")
    req = urllib.request.Request(f"https://kubernetes.default.svc{path}", method=method,
                                 headers={"Authorization": "Bearer " + open(SA + "/token").read()})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.loads(r.read() or b"{}")

def kill_pod(name):
    if killer_spec.startswith("incluster:"):
        ns = killer_spec.split(":", 1)[1]
        kube("DELETE", f"/api/v1/namespaces/{ns}/pods/{name}?gracePeriodSeconds=0")
    else:
        subprocess.run(killer_spec.split() + ["delete", "pod", name, "--grace-period=0", "--force"], capture_output=True)

def pg_primary():
    ns = killer_spec.split(":", 1)[1]
    pods = kube("GET", f"/api/v1/namespaces/{ns}/pods?labelSelector=cnpg.io/instanceRole%3Dprimary")["items"]
    return pods[0]["metadata"]["name"]

# ---- scenarios -------------------------------------------------------------------------------------------------

def setup_steps(n):
    rows = [(i, i % 5, i) for i in range(1, n + 1)]
    if SQL:
        c = conn(); cur = c.cursor()
        cur.execute("DROP TABLE IF EXISTS bench_steps")
        cur.execute("CREATE TABLE bench_steps(id INT PRIMARY KEY, state VARCHAR(20), profile_id VARCHAR(20), "
                    "priority INT, queued_at INT, controller_id VARCHAR(40), pod_name VARCHAR(80), version INT DEFAULT 0)")
        insert_many(c, cur, "bench_steps(id,state,profile_id,priority,queued_at)", "(%s,'queued','p',%s,%s)" if engine == "pxc" else "(%s,'queued','p',%s,%s)",
                    [(i, p, q) for i, p, q in rows])
        c.commit(); cur.close(); c.close()
    else:
        rq_exec(["DROP TABLE IF EXISTS bench_steps",
                 "CREATE TABLE bench_steps(id INTEGER PRIMARY KEY, state TEXT, profile_id TEXT, priority INT, "
                 "queued_at INT, controller_id TEXT, pod_name TEXT, version INT DEFAULT 0)"])
        rq_exec([["INSERT INTO bench_steps(id,state,profile_id,priority,queued_at) VALUES (?,'queued','p',?,?)", i, p, q]
                 for i, p, q in rows], transaction=True)

def claim_three_step(cur, ctrl):
    cur.execute("SELECT id FROM bench_steps WHERE state='queued' AND profile_id='p' ORDER BY priority DESC, "
                "queued_at LIMIT 1 FOR UPDATE SKIP LOCKED")
    row = cur.fetchone()
    if row is None: return None
    cur.execute("UPDATE bench_steps SET state='dispatched', controller_id=%s, pod_name=%s, version=version+1 "
                "WHERE id=%s", (ctrl, "pod-" + str(row[0]), row[0]))
    return row[0]

def claim_single_pg(cur, ctrl):
    cur.execute("UPDATE bench_steps SET state='dispatched', controller_id=%s, pod_name='pod-'||id, version=version+1 "
                "WHERE id=(SELECT id FROM bench_steps WHERE state='queued' AND profile_id='p' ORDER BY priority DESC, "
                "queued_at LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING id", (ctrl,))
    row = cur.fetchone()
    return None if row is None else row[0]

def claimer(ctrl, claimed, form):
    if SQL:
        c = conn(); cur = c.cursor()
        while True:
            begin(c)
            rid = claim_single_pg(cur, ctrl) if form == "single" else claim_three_step(cur, ctrl)
            c.commit()
            if rid is None: break
            claimed.append(rid)
        cur.close(); c.close()
    else:
        while True:
            r = rq_exec([["UPDATE bench_steps SET state='dispatched', controller_id=?, pod_name='pod-'||id, version=version+1 "
                          "WHERE id=(SELECT id FROM bench_steps WHERE state='queued' AND profile_id='p' ORDER BY priority DESC, "
                          "queued_at LIMIT 1) AND state='queued' RETURNING id", ctrl]])
            vals = r["results"][0].get("values")
            if not vals: break
            claimed.append(vals[0][0])

def bench_claim_form(n, clients, form, label):
    setup_steps(n)
    results = [[] for _ in range(clients)]
    t0 = time.time()
    with cf.ThreadPoolExecutor(clients) as ex:
        list(ex.map(lambda i: claimer(f"ctrl{i}", results[i], form), range(clients)))
    dt = time.time() - t0
    total = sum(len(r) for r in results)
    allc = set(x for r in results for x in r)
    report(f"claim_{n}_steps_{clients}_clients_{label}_s", f"{dt:.2f}")
    report(f"claim_{n}_steps_{clients}_clients_{label}_per_s", f"{n/dt:.0f}")
    assert total == n, f"expected {n} claims, got {total}"
    assert len(allc) == n, f"a step was claimed twice: {total - len(allc)} duplicate(s)"
    print(f"  OK: all {n} steps claimed exactly once")

def bench_claim(n=300, clients=8):
    if engine == "postgres":
        bench_claim_form(n, clients, "single", "single_statement")
        bench_claim_form(n, clients, "three", "three_step")
    elif engine == "pxc":
        bench_claim_form(n, clients, "three", "three_step")
    else:
        bench_claim_form(n, clients, "single", "single_statement")

def bench_single_write_latency(reps=200):
    if SQL:
        c = conn(); cur = c.cursor()
        cur.execute("DROP TABLE IF EXISTS bench_ctr"); cur.execute("CREATE TABLE bench_ctr(id INT PRIMARY KEY, n INT)")
        cur.execute("INSERT INTO bench_ctr VALUES (1,0)"); c.commit()
    else:
        rq_exec(["DROP TABLE IF EXISTS bench_ctr", "CREATE TABLE bench_ctr(id INTEGER PRIMARY KEY, n INT)"])
        rq_exec([["INSERT INTO bench_ctr VALUES (1,0)"]])
    ms = []
    for _ in range(reps):
        t = time.time()
        if SQL:
            begin(c); cur.execute("UPDATE bench_ctr SET n=n+1 WHERE id=1"); c.commit()
        else:
            rq_exec([["UPDATE bench_ctr SET n=n+1 WHERE id=1"]])
        ms.append((time.time() - t) * 1000)
    if SQL: cur.close(); c.close()
    ms.sort()
    report("single_write_p50_ms", f"{statistics.median(ms):.1f}")
    report("single_write_p95_ms", f"{ms[int(len(ms)*0.95)-1]:.1f}")
    report("single_write_writes_per_s_sequential", f"{1000/statistics.median(ms):.0f}")

def bench_batch_insert(n=500):
    def reset():
        if SQL:
            c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS bench_bi")
            cur.execute("CREATE TABLE bench_bi(id INT PRIMARY KEY, v INT)"); c.commit()
            return c, cur
        rq_exec(["DROP TABLE IF EXISTS bench_bi", "CREATE TABLE bench_bi(id INTEGER PRIMARY KEY, v INT)"])
        return None, None
    c, cur = reset()
    t0 = time.time()
    if SQL:
        insert_many(c, cur, "bench_bi(id,v)", "(%s,%s)", [(i, i) for i in range(1, n + 1)])
        c.commit()
    else:
        rq_exec([["INSERT INTO bench_bi(id,v) VALUES (?,?)", i, i] for i in range(1, n + 1)], transaction=True)
    dt_batch = time.time() - t0
    report(f"batch_insert_{n}_rows_one_statement_rows_per_s", f"{n/dt_batch:.0f}")
    c, cur = reset()
    t0 = time.time()
    for i in range(1, n + 1):
        if SQL:
            begin(c); cur.execute("INSERT INTO bench_bi(id,v) VALUES (%s,%s)", (i, i)); c.commit()
        else:
            rq_exec([["INSERT INTO bench_bi(id,v) VALUES (?,?)", i, i]])
    dt_single = time.time() - t0
    report(f"single_insert_{n}_rows_rows_per_s", f"{n/dt_single:.0f}")
    if SQL: cur.close(); c.close()

def bench_cas_race(pairs=100):
    if SQL:
        c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS bench_cas")
        cur.execute("CREATE TABLE bench_cas(id INT PRIMARY KEY, version INT)")
        for i in range(1, pairs + 1): cur.execute("INSERT INTO bench_cas VALUES (%s,1)", (i,))
        c.commit(); cur.close(); c.close()
    else:
        rq_exec(["DROP TABLE IF EXISTS bench_cas", "CREATE TABLE bench_cas(id INTEGER PRIMARY KEY, version INT)"])
        rq_exec([["INSERT INTO bench_cas VALUES (?,1)", i] for i in range(1, pairs + 1)], transaction=True)
    wins = [0, 0]
    _cas_tls = threading.local()
    def race(i, side):
        if SQL:
            c = getattr(_cas_tls, "c", None)
            if c is None:
                c = conn(); _cas_tls.c = c
            cur = c.cursor()
            begin(c); cur.execute("UPDATE bench_cas SET version=2 WHERE id=%s AND version=1", (i,)); c.commit()
            ok = cur.rowcount == 1
            cur.close()
        else:
            r = rq_exec([["UPDATE bench_cas SET version=2 WHERE id=? AND version=1", i]])
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
    assert killer_spec, "node-kill test needs the third argument (incluster:<namespace> or a kubectl prefix)"
    if engine == "pxc":
        c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS bench_acked")
        cur.execute("CREATE TABLE bench_acked(id INT PRIMARY KEY)"); c.commit()
        cur.execute("SELECT @@hostname"); target_pod = cur.fetchone()[0].split(".")[0]
        cur.close(); c.close()
        report("primary_before", target_pod)
    elif engine == "postgres":
        c = conn(); cur = c.cursor(); cur.execute("DROP TABLE IF EXISTS bench_acked")
        cur.execute("CREATE TABLE bench_acked(id INT PRIMARY KEY)"); c.commit(); cur.close(); c.close()
        target_pod = pg_primary()
        report("primary_before", target_pod)
    else:
        rq_exec(["DROP TABLE IF EXISTS bench_acked", "CREATE TABLE bench_acked(id INTEGER PRIMARY KEY)"])
        nodes = http_("GET", "/nodes")
        target_pod = next(k for k, v in nodes.items() if v.get("leader"))
        report("leader_before", target_pod)

    acked = []
    killed = threading.Event(); kill_at = [0.0]
    def killer():
        time.sleep(2.0)
        kill_pod(target_pod)
        kill_at[0] = time.time(); killed.set()
    threading.Thread(target=killer, daemon=True).start()

    t0 = time.time(); i = 0; max_gap = 0.0; last_ack = 0.0
    errors = []; ack_times = []
    if SQL: c = conn(); cur = c.cursor()
    while True:
        i += 1
        try:
            if SQL:
                begin(c); cur.execute("INSERT INTO bench_acked(id) VALUES (%s)", (i,)); c.commit()
                ok = cur.rowcount == 1
            else:
                r = rq_exec([["INSERT INTO bench_acked(id) VALUES (?)", i]])
                ok = r["results"][0].get("rows_affected", 0) == 1
            if ok:
                acked.append(i); ack_times.append(time.time())
                if killed.is_set():
                    now = time.time()
                    if last_ack: max_gap = max(max_gap, now - last_ack)
                    last_ack = now
        except Exception:
            errors.append(time.time())
            if SQL:
                try: c.close()
                except Exception: pass
                try:
                    c = conn(); cur = c.cursor()
                except Exception: time.sleep(0.05)
        if killed.is_set():
            now = time.time()
            # stop once writes have been healthy for 8 s after the last error, or after 15 s without any error,
            # or after 90 s at most
            if errors and ack_times and ack_times[-1] > errors[-1] and now - errors[-1] > 8.0: break
            if not errors and now - kill_at[0] > 15.0: break
        if time.time() - t0 > 100.0: break
    if SQL:
        try: cur.close(); c.close()
        except Exception: pass

    have = set()
    for attempt in range(30):
        try:
            if SQL:
                c = conn(); cur = c.cursor(); cur.execute("SELECT id FROM bench_acked")
                have = set(r[0] for r in cur.fetchall()); cur.close(); c.close()
            else:
                q = rq_query([["SELECT id FROM bench_acked"]])
                have = set(r[0] for r in (q["results"][0].get("values") or []))
            break
        except Exception:
            time.sleep(1)
    lost = [a for a in acked if a not in have]
    report("acked_writes", len(acked))
    report("lost_acked_writes", len(lost))
    report("max_gap_between_acked_writes_after_kill_s", f"{max_gap:.2f}")
    report("failed_attempts", len(errors))
    if errors:
        before = [t for t in ack_times if t < errors[0]]
        after = [t for t in ack_times if t > errors[-1]]
        if before and after:
            report("write_unavailability_s", f"{after[0] - before[-1]:.2f}")
        report("first_error_after_kill_s", f"{errors[0] - kill_at[0]:.2f}")
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
