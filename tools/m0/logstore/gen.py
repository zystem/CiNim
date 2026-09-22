#!/usr/bin/env python3
"""CI-like log lines (same vocabulary as tools/m0/zinc/loadgen), one JSON object per line:
{"job","ln","ts_ms","msg"}. Usage: gen.py OUT JOBS LINES_PER_JOB"""
import json, random, sys
words = ("compiling linking testing module package resolving downloading cache hit miss warning error info step build target "
         "artifact upload checksum passed failed retry timeout network registry image layer pull push deploy helm apply rollout "
         "ready pod node volume mount secret token config schema migrate index query window").split()
out, jobs, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = random.Random(42)
base = 1789900000000  # 2026-09-20, in the past for Loki (reject too-new samples)
with open(out, "w") as f:
    for j in range(1, jobs + 1):
        for ln in range(1, n + 1):
            ts = base + j * 10_000_000 + ln          # ms; unique and increasing per job
            parts = []
            for _ in range(6 + r.randrange(10)):
                w = r.choice(words)
                if r.randrange(4) == 0: w += "=" + str(r.randrange(100000))
                parts.append(w)
            msg = f"[step-{ln // 100000}] " + " ".join(parts)
            f.write(json.dumps({"job": f"job-{j}", "ln": ln, "ts_ms": ts, "msg": msg}) + "\n")
