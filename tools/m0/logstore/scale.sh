#!/bin/bash
# usage: scale.sh CHUNKDIR REPS   ingest REPS x 5M lines into a single VictoriaLogs at :9428 (streams job x rep)
for rep in $(seq 1 "$2"); do
  ls "$1"/*.jsonl | xargs -P 4 -I{} curl -s -o /dev/null -w '' -H 'Content-Type: application/x-ndjson' --data-binary @{} \
    "http://127.0.0.1:9428/insert/jsonline?_stream_fields=job,rep&_msg_field=_msg&_time_field=_time&extra_fields=rep=$rep"
  echo "rep $rep done $(date +%s)"
done
