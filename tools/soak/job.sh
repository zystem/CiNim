#!/bin/sh
# The soak as one run of a step of a pipeline (.woodpecker/soak.yaml). Usage: job.sh ROOT [HOURS=72]
# A directory of its own is made for the run in ROOT, named by the start time (20261114T180000Z), so that the runs of the weeks do not mix on the one volume;
# tools/soak/run72.sh runs in it for HOURS (both harnesses, in the foreground); the summary and one row an hour of the release run are printed (the log of the Pod
# is the report); and the exit code is the verdict of tools/soak/verdict.sh, so a soak that went bad is a pipeline that failed. After the run only the newest
# SOAK_KEEP_RUNS (8) directories named like that stay in ROOT. SOAK_RUN72 names another launcher (the test of this script has one that waits for nothing).
set -u
ROOT="${1:?directory of the volume}"; HOURS="${2:-72}"; KEEP="${SOAK_KEEP_RUNS:-8}"
HERE=$(cd "$(dirname "$0")" && pwd)
RUN72="${SOAK_RUN72:-$HERE/run72.sh}"
OUT="$ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" || { echo "job: cannot make $OUT"; exit 2; }
echo "job: soak of $HOURS hours into $OUT"
rc=0
FOREGROUND=1 "$RUN72" "$OUT" "$HOURS" || rc=1
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
