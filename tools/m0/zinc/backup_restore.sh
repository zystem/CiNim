#!/bin/bash
# Backup, verification and restore of a lost replica with the reference Go coordinator (spike 5). Usage: backup_restore.sh BINDIR
set -u
BIN="${1:?bin dir}"; D=/tmp/zinc-br; A="admin:Complexpass#123"; TOKEN=secret; H="Authorization: Bearer $TOKEN"
rm -rf $D; mkdir -p $D $D/work
~/go/bin/nats-server -js -sd $D/nats -p 4224 > $D/nats.log 2>&1 & echo $! > $D/nats.pid; sleep 1
node() { ZINC_FIRST_ADMIN_USER=admin ZINC_FIRST_ADMIN_PASSWORD='Complexpass#123' ZINC_DATA_PATH=$D/$1 ZINC_SERVER_PORT=$2 ZINC_STREAM_ENABLE=true \
  ZINC_STREAM_URL=nats://127.0.0.1:4224 ZINC_STREAM_CONSUMER=$1 ZINC_BACKUP_PATH=$D/backup-$1 ZINC_TELEMETRY=false $BIN/zincsearch > $D/$1.log 2>&1 & echo $! > $D/$1.pid; }
cnt() { curl -s -u "$A" localhost:$1/es/logs/_search -H 'Content-Type: application/json' -d '{"size":0,"track_total_hits":true,"query":{"match_all":{}}}' | python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null; }
"$BIN/loadgen" -url nats://127.0.0.1:4224 -create -n 0 -index logs -variant 6 -padid > /dev/null 2>&1
node zinc-a 4083; node zinc-b 4084; sleep 3
export ZINC_FIRST_ADMIN_USER=admin ZINC_FIRST_ADMIN_PASSWORD='Complexpass#123'   # needed by the zincsearch binary the coordinator runs for verify-backup --deep
export COORD_NODES=zinc-a=http://127.0.0.1:4083,zinc-b=http://127.0.0.1:4084 COORD_NODE_USER=admin COORD_NODE_PASSWORD='Complexpass#123' COORD_NATS_URL=nats://127.0.0.1:4224 \
  COORD_ENSURE_STREAM=true COORD_BLOB=fs COORD_FS_PATH=$D/blob COORD_TOKEN=$TOKEN COORD_LISTEN=127.0.0.1:8091 COORD_BUFFER_DIR=$D/buffer COORD_WORK_DIR=$D/work \
  COORD_ZINC_BIN=$BIN/zincsearch COORD_BACKUP_INTERVAL=-1s COORD_VERIFY_INTERVAL=-1s
"$BIN/zinccoordinator" > $D/coord.log 2>&1 & echo $! > $D/coord.pid; sleep 4
"$BIN/loadgen" -url nats://127.0.0.1:4224 -index logs -n 300000 -start 1 -padid > /dev/null 2>&1
until [ "$(cnt 4084)" = "300000" ]; do sleep 2; done; echo "replica has 300000 docs; index size $(du -sm $D/zinc-b | cut -f1) MiB"
T=$(date +%s.%N); curl -s -X POST -H "$H" localhost:8091/v1/backups > $D/bk.json; 
until curl -s -H "$H" localhost:8091/v1/backups | grep -q '"uploaded"\|"verified"'; do sleep 1; done
echo "backup uploaded in $(python3 -c "print(round($(date +%s.%N)-$T,1))") s: $(curl -s -H "$H" localhost:8091/v1/backups | python3 -c "import sys,json; d=json.load(sys.stdin); b=(d if isinstance(d,list) else d.get('backups',d))[0]; print({k:b[k] for k in b if k in ('name','size','status','node','last_applied')})")"
T=$(date +%s.%N); V=$(curl -s -m 280 -X POST -H "$H" localhost:8091/v1/verify)
echo "verify (checksum + deep restore in a scratch node) answered in $(python3 -c "print(round($(date +%s.%N)-$T,1))") s: $V"
curl -s -H "$H" localhost:8091/v1/backups | python3 -c "import sys,json; d=json.load(sys.stdin); print('backup statuses:', [(b.get('name','')[-12:], b.get('status')) for b in (d if isinstance(d,list) else d.get('backups',[]))])"
# lose the replica's disk, publish more, restore from the backup
kill -9 $(cat $D/zinc-b.pid); sleep 1; rm -rf $D/zinc-b
"$BIN/loadgen" -url nats://127.0.0.1:4224 -index logs -n 50000 -start 300001 -padid > /dev/null 2>&1
curl -s -X POST -H "$H" localhost:8091/v1/backups > /dev/null; sleep 6   # a second backup so the stream must NOT be replayed from the start
T=$(date +%s.%N)
"$BIN/zinccoordinator" fetch-backup -out $D/restore.tgz > $D/fetch.log 2>&1; ls -la $D/restore.tgz | awk '{print "fetched backup", $5/1048576 " MiB"}'
ZINC_FIRST_ADMIN_USER=admin ZINC_FIRST_ADMIN_PASSWORD='Complexpass#123' ZINC_DATA_PATH=$D/zinc-b $BIN/zincsearch restore $D/restore.tgz > $D/restore.log 2>&1; echo "restored files: $(du -sm $D/zinc-b | cut -f1) MiB"
node zinc-b 4084
until [ "$(cnt 4084)" = "350000" ]; do sleep 2; done
echo "lost replica rebuilt and caught up to 350000 docs in $(python3 -c "print(round($(date +%s.%N)-$T,1))") s (fetch + restore + stream catch-up)"
kill $(cat $D/*.pid) 2>/dev/null
