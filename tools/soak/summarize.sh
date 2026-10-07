#!/bin/bash
# What a 72 h soak (tools/soak/run72.sh) left in its output directory, in a few lines: how long it ran, the RSS of the release run at the end
# of its warm-up and at the end, the growth against the 2 % of NFR-013, the counters of failures, and for the ASan/LSan hours how many ended
# well and what LeakSanitizer said. Usage: summarize.sh OUTDIR
set -u
D="${1:?output directory of run72.sh}"
[ -f "$D/release.csv" ] || { echo "no release.csv in $D"; exit 2; }
echo "== release run ($(basename "$D"))"
head -1 "$D/release.csv" | sed 's/^/columns: /'
awk -F, 'NR>1 {n++; last=$0} END {printf "samples: %d (one a minute: %.1f h), last: %s\n", n, n/60, last}' "$D/release.csv"
tail -3 "$D/release.out" 2>/dev/null | sed 's/^/  /'
echo "== AddressSanitizer / LeakSanitizer hours"
if [ -f "$D/san-summary.txt" ]; then
  total=$(grep -c '^hour ' "$D/san-summary.txt"); ok=$(grep -c 'exit=0$' "$D/san-summary.txt")
  echo "hours finished: $total, with exit 0: $ok"; grep -v 'exit=0$' "$D/san-summary.txt" | head -5
else echo "no san-summary.txt yet"; fi
leaks=$(grep -l "LeakSanitizer\|ERROR: AddressSanitizer" "$D"/san-*.out 2>/dev/null | wc -l)
echo "hours whose output reports LeakSanitizer or AddressSanitizer errors: $leaks"
grep -h "SOAK " "$D"/san-*.out 2>/dev/null | tail -2 | sed 's/^/  /'
[ -f "$D/finished" ] && echo "finished: $(cat "$D/finished")"
