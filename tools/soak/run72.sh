#!/bin/bash
# Spike 6 launcher (NFR-013). Usage: run72.sh OUTDIR [HOURS=72]
# 1) build/soak: one continuous run, RSS growth after a 1 h warm-up must stay <= 2%.
# 2) build/soak-san: hourly ASan/LSan runs back to back (ASan's allocator keeps freed memory, so RSS
#    grows ~0.8 MB/s under connect churn; an hour-long run keeps it bounded); LSan reports at each exit.
# Pids: OUTDIR/pids. Each run keeps its CSV and output in OUTDIR.
set -u
OUT="$(realpath -m "${1:?outdir}")"; HOURS="${2:-72}"; mkdir -p "$OUT"; cd "$(dirname "$0")/../.."
SOAK_PORT=19720 SOAK_SECONDS=$((HOURS*3600)) SOAK_SAMPLE_SECONDS=60 SOAK_WARMUP_SECONDS=3600 \
  SOAK_CSV="$OUT/release.csv" setsid nohup build/soak > "$OUT/release.out" 2>&1 < /dev/null &
echo $! > "$OUT/pids"
(
  for i in $(seq 1 "$HOURS"); do
    SOAK_PORT=19721 SOAK_SECONDS=3600 SOAK_SAMPLE_SECONDS=60 SOAK_WARMUP_SECONDS=600 SOAK_MAX_GROWTH_PCT=100000 \
      SOAK_CSV="$OUT/san-$i.csv" ASAN_OPTIONS=detect_leaks=1:quarantine_size_mb=4 \
      build/soak-san > "$OUT/san-$i.out" 2>&1 < /dev/null
    echo "hour $i exit=$?" >> "$OUT/san-summary.txt"
  done
  echo finished >> "$OUT/san-summary.txt"
) > /dev/null 2>&1 < /dev/null &
disown -a
