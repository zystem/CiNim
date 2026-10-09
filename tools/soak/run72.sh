#!/bin/bash
# Soak launcher (NFR-013). Usage: run72.sh OUTDIR [HOURS=72]
# Build first: nim c -d:release -o:build/soak tools/soak/soak.nim
#              nim c -d:sanitize --passC:-fsanitize=address --passL:-fsanitize=address \
#                --passC:-fno-omit-frame-pointer -o:build/soak-san tools/soak/soak.nim
# (soak.nim needs
# tests/certs/curve/{core,client}.{pub,key}, see tools/zmq/gen_curve_keys.sh, and a libzmq.so with
# CURVE support on the loader path at run time.)
# 1) build/soak: one continuous run, RSS growth after a 1 h warm-up must stay <= 2%.
# 2) build/soak-san: hourly ASan/LSan runs back to back (ASan's allocator keeps freed memory, so RSS
#    grows ~0.8 MB/s under connect churn; an hour-long run keeps it bounded); LSan reports at each exit.
# Pids: OUTDIR/pids. Each run keeps its CSV and output in OUTDIR.
# An ASan hour is cut off at SOAK_SAN_OUT_KIB of output (1 GiB): on a kernel with vm.mmap_rnd_bits=32 an ASan binary built with an old libasan (gcc 12) crashes
# at start now and then and then prints `AddressSanitizer:DEADLYSIGNAL` for ever (327 GiB in 32 hours filled the disk of a test node and the pod was evicted). The
# process then ends with SIGXFSZ (exit 153), and a run that died in its first SOAK_SAN_START_SECONDS is made again (at most SOAK_SAN_ATTEMPTS times).
# The cure for the crash itself is `sysctl vm.mmap_rnd_bits=28` on the node.
set -u
OUT="$(realpath -m "${1:?outdir}")"; HOURS="${2:-72}"; mkdir -p "$OUT"; cd "$(dirname "$0")/../.."
BIN="${SOAK_BIN:-build/soak}"; SAN_BIN="${SOAK_SAN_BIN:-build/soak-san}"
SAN_OUT_KIB="${SOAK_SAN_OUT_KIB:-1048576}"; SAN_START="${SOAK_SAN_START_SECONDS:-10}"; SAN_ATTEMPTS="${SOAK_SAN_ATTEMPTS:-3}"
SOAK_PORT=19720 SOAK_SECONDS=$((HOURS*3600)) SOAK_SAMPLE_SECONDS=60 SOAK_WARMUP_SECONDS=3600 \
  SOAK_CSV="$OUT/release.csv" setsid nohup "$BIN" > "$OUT/release.out" 2>&1 < /dev/null &
echo $! > "$OUT/pids"
(
  for i in $(seq 1 "$HOURS"); do
    for attempt in $(seq 1 "$SAN_ATTEMPTS"); do
      started=$(date +%s)
      (
        ulimit -f "$SAN_OUT_KIB"
        SOAK_PORT=19721 SOAK_SECONDS=${SOAK_SAN_SECONDS:-3600} SOAK_SAMPLE_SECONDS=60 SOAK_WARMUP_SECONDS=600 SOAK_MAX_GROWTH_PCT=100000 \
          SOAK_CSV="$OUT/san-$i.csv" ASAN_OPTIONS=detect_leaks=1:quarantine_size_mb=4 \
          exec "$SAN_BIN" > "$OUT/san-$i.out" 2>&1 < /dev/null
      )
      code=$?
      echo "attempt $attempt of hour $i exit=$code" >> "$OUT/san-summary.txt"      # (summarize.sh counts the lines that start with `hour `)
      [ "$code" -eq 0 ] && break
      [ $(( $(date +%s) - started )) -ge "$SAN_START" ] && break     # it ran for a while: that is a result, not a failed start
    done
    echo "hour $i exit=$code" >> "$OUT/san-summary.txt"
  done
  echo finished >> "$OUT/san-summary.txt"
) > /dev/null 2>&1 < /dev/null &
[ "${FOREGROUND:-0}" = 1 ] || disown -a   # disowned jobs would make the `wait` below return at once
# FOREGROUND=1: stay alive until both runs finish, so a process supervisor (systemd-run on the soak host)
# owns them - without it this script exits right away and a supervisor would take that for "service done".
[ "${FOREGROUND:-0}" = 1 ] && wait
