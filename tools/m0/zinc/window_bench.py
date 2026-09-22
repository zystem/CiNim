import json, random, time, urllib.request, base64, sys
AUTH = "Basic " + base64.b64encode(b"admin:Complexpass#123").decode()
def window(frm, size, index, job="job-big", port=4080):
    s, e = frm // 100, (frm + size - 1) // 100                    # 100-line blocks that cover the window
    should = [{"prefix": {"_id": f"{job}:{b * 100:010d}"[:-2]}} for b in range(s, e + 1)]
    body = {"query": {"bool": {"should": should, "minimum_should_match": 1}}, "sort": [{"_id": "asc"}],
            "size": 100 * (e - s + 1), "_source": ["ln"]}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/es/{index}/_search", data=json.dumps(body).encode(),
                                 headers={"Authorization": AUTH, "Content-Type": "application/json"})
    t = time.perf_counter(); raw = urllib.request.urlopen(req).read(); dt = (time.perf_counter() - t) * 1000
    hits = json.loads(raw)["hits"]["hits"]
    ids = [h["_id"] for h in hits]
    off = ids.index(f"{job}:{frm:010d}")                           # the gateway trims the block edges
    win = hits[off:off + size]
    assert len(win) == size, (frm, len(hits))
    return dt
index, N, maxln = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for size in (200, 500):
    for label, lo, hi in [("start", 1, maxln // 100), ("middle", maxln * 49 // 100, maxln * 51 // 100), ("end", maxln * 98 // 100, maxln - size - 200)]:
        xs = sorted(window(random.randint(lo, hi), size, index) for _ in range(N))
        print(f"{index} window={size:3d} {label:7s} n={N} p50={xs[N//2]:.1f} ms p95={xs[int(N*0.95)]:.1f} ms max={xs[-1]:.1f} ms")
