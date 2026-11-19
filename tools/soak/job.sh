#!/bin/sh
# The soak as one run of a step of a pipeline (.woodpecker/soak.yaml). Usage: job.sh ROOT [HOURS=72]
# A directory of its own is made for the run in ROOT, named by the start time (20261114T180000Z), so that the runs of the weeks do not mix on the one volume;
# tools/soak/run72.sh runs in it for HOURS (both harnesses, in the foreground); the summary and one row an hour of the release run are printed (the log of the Pod
# is the report); and the exit code is the verdict of tools/soak/verdict.sh, so a soak that went bad is a pipeline that failed. After the run only the newest
# SOAK_KEEP_RUNS (8) directories named like that stay in ROOT. SOAK_RUN72 names another launcher (the test of this script has one that waits for nothing).
# A line an hour goes to the log while the soak runs (SOAK_HEARTBEAT_SECONDS, 3600): the last sample of the release run and the ASan hours so far. The first full soak of 72 hours (Woodpecker
# pipeline 14, 2026-11-16..19) failed and kept 3 lines of log: a step that says nothing for 72 hours loses its stream, and the volume with the report is deleted with the pipeline, so the
# summary and the verdict that are printed at the end never arrived and the reason of the failure is not known. With a line an hour the log is the report up to the point where it stops.
set -u
ROOT="${1:?directory of the volume}"; HOURS="${2:-72}"; KEEP="${SOAK_KEEP_RUNS:-8}"
HERE=$(cd "$(dirname "$0")" && pwd)
RUN72="${SOAK_RUN72:-$HERE/run72.sh}"
OUT="$ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" || { echo "job: cannot make $OUT"; exit 2; }
echo "job: soak of $HOURS hours into $OUT"
rc=0
HEARTBEAT="${SOAK_HEARTBEAT_SECONDS:-3600}"
heartbeat() {
  n=0
  sp=0
  trap 'kill "$sp" 2>/dev/null; exit 0' TERM
  while :; do
    sleep "$HEARTBEAT" >/dev/null 2>&1 & sp=$!   # no output of its own, so that one left behind cannot hold the pipe of whoever reads the log
    wait "$sp"                                   # `wait` is interrupted by the TERM that ends the heartbeat (the trap kills the sleep); a plain sleep would hold it
    n=$((n + 1))
    echo "== heartbeat $n $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "release: $(tail -n 1 "$OUT/release.csv" 2>/dev/null || echo 'no sample yet')"
    if [ -f "$OUT/san-summary.txt" ]; then
      total=$(grep -c '^hour ' "$OUT/san-summary.txt" || true); good=$(grep -c '^hour .* exit=0$' "$OUT/san-summary.txt" || true)
      echo "asan hours: $total finished, $good with exit 0$(grep '^hour ' "$OUT/san-summary.txt" | grep -v 'exit=0$' | tail -n 3 | sed 's/^/; /' | tr -d '\n')"
    else
      echo "asan hours: none yet"
    fi
  done
}
heartbeat &
hb=$!
FOREGROUND=1 "$RUN72" "$OUT" "$HOURS" || rc=1
kill "$hb" 2>/dev/null || true
wait "$hb" 2>/dev/null || true
"$HERE/summarize.sh" "$OUT" || true
echo "== the release run, one row an hour"; awk -F, 'NR == 1 || (NR - 1) % 60 == 0' "$OUT/release.csv" 2>/dev/null || true
"$HERE/verdict.sh" "$OUT" "$HOURS" || rc=1
# keep the newest runs (the names sort by time); what is not named like a run is left alone
runs=$(find "$ROOT" -maxdepth 1 -type d -name '[0-9]*T[0-9]*Z' | sort)
n=$(printf '%s\n' "$runs" | grep -c . || true)
if [ "$n" -gt "$KEEP" ]; then
  printf '%s\n' "$runs" | head -n "$((n - KEEP))" | while IFS= read -r old; do
    [ "$old" = "$OUT" ] || { echo "job: removing the old run $old"; rm -rf -- "$old"; }
  done
fi
exit "$rc"
