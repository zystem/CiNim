import json, time, urllib.request, base64, sys, resource
AUTH = "Basic " + base64.b64encode(b"admin:Complexpass#123").decode()
node_pid = int(open("/tmp/zinc-m0/node-a.pid").read())
def node_rss(): return int(open(f"/proc/{node_pid}/statm").read().split()[1]) * 4 // 1024
def block(index, job, b):      # 10 000 lines per prefix: drop the last 4 digits
    prefix = f"{job}:{b * 10000:010d}"[:-4]
    body = {"query": {"prefix": {"_id": prefix}}, "sort": [{"_id": "asc"}], "size": 10000, "_source": ["line"]}
    req = urllib.request.Request(f"http://127.0.0.1:4080/es/{index}/_search", data=json.dumps(body).encode(), headers={"Authorization": AUTH, "Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req).read())["hits"]["hits"]
index, job, total = sys.argv[1], "job-big", int(sys.argv[2])
t0 = time.time(); n = 0; peak_node = 0; nbytes = 0; last = None; ok = True
for b in range(0, total // 10000 + 1):
    hits = block(index, job, b)
    for h in hits:
        if last is not None and h["_id"] <= last: ok = False
        last = h["_id"]; n += 1; nbytes += len(h["_source"].get("line", ""))
    peak_node = max(peak_node, node_rss())
dt = time.time() - t0
print(f"export {n} lines in {dt:.1f}s = {n/dt:.0f} lines/s, {nbytes/1048576/dt:.1f} MiB/s text, in order={ok}, node RSS peak {peak_node} MiB, client maxrss {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss//1024} MiB")
