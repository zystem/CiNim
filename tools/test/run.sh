#!/bin/bash
# Runs the unit and integration test files in parallel: tools/test/run.sh [-j N] [-u|-i] [file.nim ...]
#   -j N   workers (default 8); every worker has its own scratch rqlite in a Docker container (RAM-backed), so the suites do not meet in one database
#   -u|-i  only the unit tests / only the integration tests (default: both)
# Needs Docker for the integration tests. The containers (cinim-rqlite-N, ports 24600+N) are made new at every run and left running afterwards; remove them with
#   docker rm -f $(docker ps -aq --filter name=cinim-rqlite-)
# The log of a file that failed is build/test-logs/<name>.log. Exit code: the number of failed files (capped at 100).
cd "$(dirname "$0")/../.." || exit 2
jobs=8; unit=1; integ=1; files=()
while [ $# -gt 0 ]; do
  case $1 in
    -j) jobs=$2; shift 2;;
    -u) integ=0; shift;;
    -i) unit=0; shift;;
    *) files+=("$1"); shift;;
  esac
done
if [ ${#files[@]} -eq 0 ]; then
  [ $integ = 1 ] && for f in tests/integration/t*.nim; do
    case $f in *tm1skeleton*) continue;; esac     # needs the Kubernetes C client (K8S_PREFIX) and a cluster: name it on the command line
    files+=("$f")
  done
  [ $unit = 1 ] && for f in tests/unit/t*.nim; do
    case $f in *tkekclient_tls*|*thsperf*) continue;; esac     # the TLS test needs -d:ssl and Python, the performance test is a benchmark
    files+=("$f")
  done
fi
mkdir -p build/tests build/test-logs
need_db=0; for f in "${files[@]}"; do case $f in tests/integration/*) need_db=1;; esac; done
if [ $need_db = 1 ]; then
  command -v docker >/dev/null || { echo "docker is needed for the integration tests"; exit 2; }
  for ((i = 0; i < jobs; i++)); do
    name=cinim-rqlite-$i
    docker rm -f $name >/dev/null 2>&1       # always a fresh, empty database: what an earlier run left in it must not matter
    docker run -d --name $name -p 127.0.0.1:$((24600 + i)):4001 --tmpfs /rqlite/file:rw,size=512m,mode=1777 rqlite/rqlite:latest -fk -disco-mode= >/dev/null || exit 2
  done
  for ((i = 0; i < jobs; i++)); do
    until curl -sf "127.0.0.1:$((24600 + i))/readyz" >/dev/null; do sleep 0.5; done
  done
fi
export jobs
one() {   # file slot
  f=$1; slot=$2; kind=$(basename "$(dirname "$f")"); name=$(basename "$f" .nim); log=build/test-logs/$kind-$name.log
  mkdir -p build/tests/$kind     # unit and integration files may share a name: their binaries and logs must not
  case $f in tests/integration/*) export CINIM_RQLITE_URL=http://127.0.0.1:$((24600 + slot));; *) unset CINIM_RQLITE_URL;; esac
  start=$(date +%s)
  nim c -r --hints:off --warnings:off -p:src --outdir:build/tests/$kind "$f" >"$log" 2>&1
  rc=$?
  ok=$(grep -c '\[OK\]' "$log"); bad=$(grep -c '\[FAILED\]' "$log")
  if [ $rc -eq 0 ] && [ "$bad" = 0 ]; then printf 'ok    %-34s %3d tests %4ds\n' "$kind/$name" "$ok" $(( $(date +%s) - start )); rm -f "$log"
  else printf 'FAIL  %-34s %3d ok, %d failed, exit %d  (%s)\n' "$kind/$name" "$ok" "$bad" $rc "$log"; fi
}
export -f one
# a free slot number for every job: xargs -P gives no slot, so a slot is a lock directory
slotdir=$(mktemp -d); trap 'rm -rf "$slotdir"' EXIT; export slotdir
run() {
  for ((s = 0; s < jobs; s++)); do
    if mkdir "$slotdir/$s" 2>/dev/null; then one "$1" $s; rmdir "$slotdir/$s"; return; fi
  done
  sleep 1; run "$1"
}
export -f run
printf '%s\n' "${files[@]}" | xargs -P "$jobs" -I{} bash -c 'run {}' | tee build/test-logs/summary.txt
fails=$(grep -c '^FAIL' build/test-logs/summary.txt)
echo "$(grep -c '^ok' build/test-logs/summary.txt) files ok, $fails failed"
exit $(( fails > 100 ? 100 : fails ))
