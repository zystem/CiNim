#!/bin/sh
# Did the soak (tools/soak/run72.sh) that wrote a directory pass? Usage: verdict.sh OUTDIR [HOURS]
# It passes (exit 0) when the release run ended with `SOAK OK` (RSS growth after the warm-up within 2 %, NFR-013), every ASan/LSan hour ended with
# exit 0, and the launcher said `finished`; with HOURS also when that many ASan hours were run. 1: it did not pass (the reasons are printed). 2: nothing to judge.
# The step of .woodpecker/soak.yaml ends with this verdict as its exit code, so that a soak that went bad is a pipeline that failed.
set -u
D="${1:?output directory of run72.sh}"; HOURS="${2:-}"
[ -f "$D/release.out" ] || { echo "verdict: no release.out in $D"; exit 2; }
rc=0
last=$(tail -n 1 "$D/release.out" 2>/dev/null || true)
case "$last" in
  "SOAK OK"*) echo "verdict: release run: $last" ;;
  *) echo "verdict: the release run did not end with SOAK OK (last line: ${last:-none})"; rc=1 ;;
esac
S="$D/san-summary.txt"
total=0; bad=0
if [ -f "$S" ]; then
  total=$(grep -c '^hour ' "$S" || true)
  bad=$(grep '^hour ' "$S" | grep -vc 'exit=0$' || true)
fi
[ "${bad:-0}" = 0 ] || { echo "verdict: $bad ASan hours did not end well (see $S)"; rc=1; }
if [ -n "$HOURS" ] && [ "${total:-0}" -lt "$HOURS" ]; then echo "verdict: only ${total:-0} of $HOURS ASan hours were run"; rc=1; fi
if [ ! -f "$S" ] || ! grep -qx finished "$S"; then echo "verdict: the launcher did not finish (no line 'finished' in $S)"; rc=1; fi
[ "$rc" = 0 ] && echo "verdict: the soak passed ($total ASan hours)"
exit "$rc"
