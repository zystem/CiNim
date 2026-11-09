#!/bin/bash
# Runs the unit and integration test files in parallel: tools/test/run.sh [-j N] [-u|-i] [file.nim ...]
#   -j N   workers (default 8); every worker has its own scratch rqlite in a Docker container (RAM-backed), so the suites do not meet in one database
#   -u|-i  only the unit tests (and the protocol contract tests, tests/contract) / only the integration tests (default: both)
# The integration tests need a scratch rqlite each. With Docker they are containers (cinim-rqlite-N, ports 24600+N), made new at every run and left running afterwards; remove them with
#   docker rm -f $(docker ps -aq --filter name=cinim-rqlite-)
# CINIM_TEST_NICE=<n> runs the compilers and the tests at that nice value, so that the databases (not niced) answer first on a busy machine.
# CINIM_TEST_FILE_TIMEOUT=<seconds> (default 900) is what a file may take, compiling it included: a file that hangs is killed and reported as failed ("TIMED OUT"), and the run goes on, instead of one
# file holding the pool until the whole run is killed by its own limit (a run of the pipeline once lost two hours to one file, with no word of which).
# Without Docker, or with CINIM_RQLITE_BIN=<path of rqlited>, they are rqlited processes of this script (ports 24600+N and 24700+N, data in /dev/shm when it has room, else in the temporary directory), stopped when it ends:
# this is how the pipeline of the repository runs the tests in a Pod (.ci/pipeline.lua; tools/image/Dockerfile.test has rqlited).
# CINIM_TEST_DBPROBE=1 measures the databases while the tests run: every second a trivial query and a one-row write to each worker's rqlite, with the load average, into build/test-logs/dbprobe.txt
# (time, worker, query s, write s, load); at the end the percentiles are printed, and the samples above one second (a test waits 8 s for a frame of a hub that waits for a query: tconductorhub).
# The write goes to the table zz_probe of the worker's database. The pipeline sets it.
# CINIM_TEST_ASAN=1 builds every file with AddressSanitizer on the system allocator (-d:useMalloc, a nimcache of its own under build/nimcache-asan, the binary in build/tests-asan) and runs it:
# a use after free or an overflow is a FAIL with the report in the log (the leaks are not looked for: ASAN_OPTIONS detect_leaks=0). It first runs tools/test/check-mmap-rnd.sh and stops with its error
# when an ASan binary would crash at start (vm.mmap_rnd_bits above 28); a start that crashed all the same (`DEADLYSIGNAL`, nothing else) is repeated, up to 3 times, and the output of a test is cut at
# 20 MB (that crash prints for ever). Meant for the files that start threads: .ci/pipeline.lua passes those (parameter ASAN, a schedule trigger makes the nightly run).
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
  [ $unit = 1 ] && for f in tests/unit/t*.nim tests/contract/t*.nim; do        # the protocol contract tests need nothing but the compiler (and buf, which tproto_compat finds in PATH)
    case $f in *thsperf*) continue;; esac     # the performance test is a benchmark
    files+=("$f")
  done
fi
mkdir -p build/tests build/test-logs
asan=${CINIM_TEST_ASAN:-0}
if [ "$asan" = 1 ]; then
  sh tools/test/check-mmap-rnd.sh || exit 2
  export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}
  mkdir -p build/tests-asan build/nimcache-asan
fi
need_db=0; for f in "${files[@]}"; do case $f in tests/integration/*) need_db=1;; esac; done
native=${CINIM_RQLITE_BIN:-}
[ -z "$native" ] && ! command -v docker >/dev/null && native=$(command -v rqlited || true)
rqpids=()
if [ $need_db = 1 ] && [ -n "$native" ]; then
  # RAM (faster, and no fsync to wait for) when /dev/shm has 150 MB for every worker (a container has 64 MiB of it by default; a job of the pipeline asks for more with `shm`), else the temporary directory
  shm=""; [ -d /dev/shm ] && [ "$(df -Pk /dev/shm | awk 'NR==2 {print $4}')" -gt $((jobs * 150000)) ] && shm=/dev/shm
  rqdir=$(mktemp -d "${shm:-${TMPDIR:-/tmp}}/cinim-rqlite.XXXXXX")
  # p is the variable of the loop inside the single-quoted trap
  # shellcheck disable=SC2154
  trap 'for p in "${rqpids[@]}"; do kill "$p" 2>/dev/null; done; wait; rm -rf "$rqdir"' EXIT
  for ((i = 0; i < jobs; i++)); do
    "$native" -node-id "n$i" -http-addr "127.0.0.1:$((24600 + i))" -raft-addr "127.0.0.1:$((24700 + i))" -fk -disco-mode= "$rqdir/$i" >"$rqdir/$i.log" 2>&1 &
    rqpids+=($!)
  done
  for ((i = 0; i < jobs; i++)); do
    until curl -sf "127.0.0.1:$((24600 + i))/readyz" >/dev/null; do
      kill -0 "${rqpids[$i]}" 2>/dev/null || { echo "rqlited $i did not start:"; cat "$rqdir/$i.log"; exit 2; }
      sleep 0.5
    done
  done
elif [ $need_db = 1 ]; then
  command -v docker >/dev/null || { echo "docker (or rqlited: CINIM_RQLITE_BIN) is needed for the integration tests"; exit 2; }
  for ((i = 0; i < jobs; i++)); do
    name=cinim-rqlite-$i
    docker rm -f $name >/dev/null 2>&1       # always a fresh, empty database: what an earlier run left in it must not matter
    docker run -d --name $name -p 127.0.0.1:$((24600 + i)):4001 --tmpfs /rqlite/file:rw,size=512m,mode=1777 rqlite/rqlite:latest -fk -disco-mode= >/dev/null || exit 2
  done
  for ((i = 0; i < jobs; i++)); do
    until curl -sf "127.0.0.1:$((24600 + i))/readyz" >/dev/null; do sleep 0.5; done
  done
fi
export jobs asan
probe_pid=""
if [ $need_db = 1 ] && [ "${CINIM_TEST_DBPROBE:-0}" = 1 ]; then
  : > build/test-logs/dbprobe.txt
  probe() {
    local i base q w
    for ((i = 0; i < jobs; i++)); do
      curl -s -o /dev/null --max-time 30 -XPOST "127.0.0.1:$((24600 + i))/db/execute" -H 'Content-Type: application/json' -d '[["CREATE TABLE IF NOT EXISTS zz_probe (t INTEGER)"]]'
    done
    while :; do
      for ((i = 0; i < jobs; i++)); do
        base="127.0.0.1:$((24600 + i))"
        q=$(LC_ALL=C curl -s -o /dev/null -w '%{time_total}' --max-time 60 "$base/db/query?q=SELECT%201")
        w=$(LC_ALL=C curl -s -o /dev/null -w '%{time_total}' --max-time 60 -XPOST "$base/db/execute" -H 'Content-Type: application/json' -d '[["INSERT INTO zz_probe VALUES (1)"]]')
        echo "$(date +%T) $i $q $w $(cut -d' ' -f1 /proc/loadavg)" >> build/test-logs/dbprobe.txt
      done
      sleep 1
    done
  }
  probe & probe_pid=$!
fi
one() {   # file slot
  f=$1; slot=$2; kind=$(basename "$(dirname "$f")"); name=$(basename "$f" .nim); log=build/test-logs/$kind-$name.log
  mkdir -p build/tests/$kind     # unit and integration files may share a name: their binaries and logs must not
  case $f in tests/integration/*) export CINIM_RQLITE_URL=http://127.0.0.1:$((24600 + slot));; *) unset CINIM_RQLITE_URL;; esac
  start=$(date +%s)
  limit=${CINIM_TEST_FILE_TIMEOUT:-900}
  if [ "$asan" = 1 ]; then
    mkdir -p build/tests-asan/$kind
    bin=build/tests-asan/$kind/$name
    attempt=0
    timeout -k 10 "$limit" ${CINIM_TEST_NICE:+nice -n $CINIM_TEST_NICE} nim c --hints:off --warnings:off -p:src -d:useMalloc --debugger:native --passC:-fsanitize=address \
      --passC:-fno-omit-frame-pointer --passL:-fsanitize=address --nimcache:build/nimcache-asan/$kind-$name --outdir:build/tests-asan/$kind "$f" >"$log" 2>&1
    rc=$?
    while [ $rc -eq 0 ]; do
      ( ulimit -f 20000; timeout -k 10 "$limit" ${CINIM_TEST_NICE:+nice -n $CINIM_TEST_NICE} "$bin" >"$log" 2>&1 )
      rc=$?
      if grep -q DEADLYSIGNAL "$log" && ! grep -q "ERROR: AddressSanitizer" "$log" && [ $attempt -lt 3 ]; then attempt=$((attempt + 1)); : >"$log"; rc=0; continue; fi
      break
    done
  else
    timeout -k 10 "$limit" ${CINIM_TEST_NICE:+nice -n $CINIM_TEST_NICE} nim c -r --hints:off --warnings:off -p:src --outdir:build/tests/$kind "$f" >"$log" 2>&1
    rc=$?
  fi
  grep -q "ERROR: AddressSanitizer" "$log" && [ $rc -eq 0 ] && rc=1
  ok=$(grep -c '\[OK\]' "$log"); bad=$(grep -c '\[FAILED\]' "$log")
  # a file that reports with the summary line of another framework (`[Summary] 4 tests run`) has no [OK] lines: its count is that of the summary, so that "0 tests" means a file that skipped itself
  if [ "$ok" = 0 ]; then n=$(sed -n 's/.*\[Summary\] \([0-9]*\) tests run.*/\1/p' "$log" | tail -1); [ -z "$n" ] || ok=$n; fi
  if [ $rc -eq 0 ] && [ "$bad" = 0 ]; then printf 'ok    %-34s %3d tests %4ds\n' "$kind/$name" "$ok" $(( $(date +%s) - start )); rm -f "$log"
  else
    [ $rc -ne 124 ] || { echo "TIMED OUT: no answer within ${limit} s, killed" >>"$log"; echo "$name: TIMED OUT after ${limit} s" >&2; }
    printf 'FAIL  %-34s %3d ok, %d failed, exit %d%s [%s-%s]  (%s)\n' "$kind/$name" "$ok" "$bad" $rc "$([ $rc -ne 124 ] || echo ' TIMED OUT')" "$(date -d "@$start" +%T 2>/dev/null)" "$(date +%T)" "$log"
  fi
}
export -f one
# a free slot number for every job: xargs -P gives no slot, so a slot is a lock directory
slotdir=$(mktemp -d)
trap 'for p in "${rqpids[@]}"; do kill "$p" 2>/dev/null; done; wait; rm -rf "$slotdir" "${rqdir:-}"' EXIT; export slotdir
run() {
  for ((s = 0; s < jobs; s++)); do
    if mkdir "$slotdir/$s" 2>/dev/null; then one "$1" $s; rmdir "$slotdir/$s"; return; fi
  done
  sleep 1; run "$1"
}
export -f run
printf '%s\n' "${files[@]}" | xargs -P "$jobs" -I{} bash -c 'run {}' | tee build/test-logs/summary.txt
if [ -n "$probe_pid" ]; then
  kill "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null
  for col in 3 4; do
    awk -v c=$col '{print $c}' build/test-logs/dbprobe.txt | LC_ALL=C sort -n | LC_ALL=C awk -v n="$([ $col = 3 ] && echo query || echo write)" \
      '{a[NR]=$1} END {if (NR) {i95 = int(NR * 0.95); if (i95 < 1) i95 = 1; printf "dbprobe %s: %d samples, p50 %.3f s, p95 %.3f s, max %.3f s\n", n, NR, a[int((NR + 1) / 2)], a[i95], a[NR]}}'
  done
  LC_ALL=C awk '$3 > 1 || $4 > 1 {print "dbprobe slow: " $0 "  (time worker query write load)"}' build/test-logs/dbprobe.txt | head -30
fi
fails=$(grep -c '^FAIL' build/test-logs/summary.txt)
echo "$(grep -c '^ok' build/test-logs/summary.txt) files ok, $fails failed"
exit $(( fails > 100 ? 100 : fails ))
