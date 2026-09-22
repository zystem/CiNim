import json, random, time, urllib.request, base64, statistics, sys
AUTH = "Basic " + base64.b64encode(b"admin:Complexpass#123").decode()
def window(frm, size=200, job="job-big", port=4080, index="logs-t1-w38"):
    body = {"query": {"bool": {"filter": [{"term": {"job": job}}, {"range": {"ln": {"gte": frm, "lt": frm + size}}}]}},
            "sort": [{"ln": "asc"}], "size": size, "_source": ["ln", "line"]}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/es/{index}/_search", data=json.dumps(body).encode(),
                                 headers={"Authorization": AUTH, "Content-Type": "application/json"})
    t = time.perf_counter(); raw = urllib.request.urlopen(req).read(); dt = (time.perf_counter() - t) * 1000
    hits = json.loads(raw)["hits"]["hits"]
    assert len(hits) == size and hits[0]["_source"]["ln"] == frm, (frm, len(hits))
    return dt
N = int(sys.argv[1]); maxln = int(sys.argv[2])
for label, lo, hi in [("start (0-1%)", 1, maxln // 100), ("middle (49-51%)", maxln * 49 // 100, maxln * 51 // 100), ("end (98-100%)", maxln * 98 // 100, maxln - 200)]:
    xs = [window(random.randint(lo, hi)) for _ in range(N)]
    xs.sort()
    print(f"{label:16s} n={N} p50={xs[N//2]:.1f} ms p95={xs[int(N*0.95)]:.1f} ms max={xs[-1]:.1f} ms")
