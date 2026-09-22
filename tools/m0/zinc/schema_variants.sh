#!/bin/bash
# Publishes 1M lines per index schema variant one after another and records searchable time, indexing rate and disk.
S=/tmp/claude-1000/-home-zystem-github-zincsearch/2a0c3794-7504-40c4-b81d-832b5901509a/scratchpad; D=/tmp/zinc-m0; A="-u admin:Complexpass#123"
for v in 1 2 3 4 5; do
  idx=v$v; t0=$(date +%s)
  $S/bin/loadgen -create -n 1 -index $idx -variant $v -start 1 > /dev/null 2>&1
  $S/bin/loadgen -index $idx -start 2 -n 999999 > /dev/null 2>&1
  until [ "$(curl -s $A localhost:4080/es/$idx/_search -H 'Content-Type: application/json' -d '{"size":0,"track_total_hits":true,"query":{"match_all":{}}}' | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null)" = "1000000" ]; do sleep 3; done
  dt=$(( $(date +%s) - t0 ))
  sz=$(du -sm $D/node-a/$idx | cut -f1)
  echo "variant $v: 1,000,000 docs searchable after ${dt}s ($((1000000/dt)) docs/s), index size ${sz} MiB ($((sz*1024*1024/1000000)) B/doc)"
done
