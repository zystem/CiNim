import json, time, urllib.request, base64, sys
AUTH = "Basic " + base64.b64encode(b"admin:Complexpass#123").decode()
def q(index, term, job="job-big"):
    body = {"query": {"bool": {"must": [{"match": {"line": term}}], "filter": [{"prefix": {"_id": job + ":"}}]}}, "size": 50, "_source": False}
    req = urllib.request.Request(f"http://127.0.0.1:4080/es/{index}/_search", data=json.dumps(body).encode(), headers={"Authorization": AUTH, "Content-Type": "application/json"})
    t = time.perf_counter(); d = json.loads(urllib.request.urlopen(req, timeout=120).read()); return (time.perf_counter() - t) * 1000, d["hits"]["total"]["value"]
for term in sys.argv[2:]:
    ms, hits = q(sys.argv[1], term)
    print(f"{sys.argv[1]} search {term!r}: {hits} matching lines, {ms:.0f} ms (first 50 by score)", flush=True)
