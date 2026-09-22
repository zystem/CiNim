#!/bin/bash
# usage: runall.sh DATA WORKDIR OUTDIR  (sequential, one store at a time)
for s in vlogs quickwit clickhouse loki; do
  python3 -u "$(dirname "$0")/bench.py" $s "$1" "$2" > "$3/$s.out" 2>&1
  rm -rf "$2/$s"
done
echo finished > "$3/done"
