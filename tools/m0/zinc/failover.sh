#!/bin/bash
# Local failover experiment for the ZincSearch fork (spike 5): NATS + two nodes + the Go coordinator (reference implementation).
# Usage: failover.sh BINDIR   (BINDIR holds zincsearch, zinccoordinator, loadgen; nats-server from ~/go/bin)
# Measures: time from killing the master to /v1/master naming the replica; data completeness after failover.
set -u
BIN="${1:?bin dir}"; D=/tmp/zinc-fo; A="admin:Complexpass#123"; TOKEN=secret
rm -rf $D; mkdir -p $D
~/go/bin/nats-server -js -sd $D/nats -p 4223 > $D/nats.log 2>&1 & echo $! > $D/nats.pid; sleep 1
node() { # name port
  ZINC_FIRST_ADMIN_USER=admin ZINC_FIRST_ADMIN_PASSWORD='Complexpass#123' ZINC_DATA_PATH=$D/$1 ZINC_SERVER_PORT=$2 ZINC_STREAM_ENABLE=true \
  ZINC_STREAM_URL=nats://127.0.0.1:4223 ZINC_STREAM_CONSUMER=$1 ZINC_BACKUP_PATH=$D/backup-$1 ZINC_TELEMETRY=false $BIN/zincsearch > $D/$1.log 2>&1 &
  echo $! > $D/$1.pid; }
"$BIN/loadgen" -url nats://127.0.0.1:4223 -create -n 0 -index logs > /dev/null 2>&1
node zinc-a 4081; node zinc-b 4082; sleep 3
COORD_NODES=zinc-a=http://127.0.0.1:4081,zinc-b=http://127.0.0.1:4082 COORD_NODE_USER=admin COORD_NODE_PASSWORD='Complexpass#123' \
COORD_NATS_URL=nats://127.0.0.1:4223 COORD_ENSURE_STREAM=true COORD_BLOB=fs COORD_FS_PATH=$D/blob COORD_TOKEN=$TOKEN COORD_LISTEN=127.0.0.1:8090 \
COORD_BUFFER_DIR=$D/buffer COORD_WORK_DIR=$D/work COORD_ZINC_BIN=$BIN/zincsearch COORD_BACKUP_INTERVAL=-1s COORD_VERIFY_INTERVAL=-1s "$BIN/zinccoordinator" > $D/coord.log 2>&1 & echo $! > $D/coord.pid
sleep 4
master() { curl -s -H "Authorization: Bearer $TOKEN" localhost:8090/v1/master; }
echo "initial master: $(master)"
"$BIN/loadgen" -url nats://127.0.0.1:4223 -index logs -n 200000 -job jobA > /dev/null 2>&1
sleep 65   # let the promote cooldown (1 min from the initial state) pass
cnt() { curl -s -u "$A" localhost:$1/es/logs/_search -H 'Content-Type: application/json' -d '{"size":0,"track_total_hits":true,"query":{"match_all":{}}}' | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null; }
echo "docs on a=$(cnt 4081) b=$(cnt 4082)"
T0=$(date +%s.%N); kill -9 $(cat $D/zinc-a.pid); echo "killed master zinc-a"
for _ in $(seq 1 300); do m=$(master); echo "$m" | grep -q zinc-b && break; sleep 0.2; done
T1=$(date +%s.%N); echo "failover took $(python3 -c "print(round($T1-$T0,1))") s: $m"
echo "docs on b after failover: $(cnt 4082)"
kill $(cat $D/*.pid) 2>/dev/null
