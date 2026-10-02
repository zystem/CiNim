#!/bin/bash
# Port-forward localhost:19428 to the VictoriaLogs node's HTTP API (read/query, port 9428).
K="kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT} -n victorialogs"
[ -f /tmp/pf-victorialogs.pid ] && kill $(cat /tmp/pf-victorialogs.pid) 2>/dev/null; sleep 1
nohup $K port-forward svc/victorialogs 19428:9428 > /tmp/pf-victorialogs.log 2>&1 &
echo $! > /tmp/pf-victorialogs.pid
sleep 2; echo "victorialogs forwarded to 127.0.0.1:19428"
