#!/bin/bash
# Port-forward localhost:19429 to vlagent's own insert endpoint (/insert/jsonline etc, port 9429).
K="kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT} -n victorialogs"
[ -f /tmp/pf-vlagent.pid ] && kill $(cat /tmp/pf-vlagent.pid) 2>/dev/null; sleep 1
nohup $K port-forward svc/vlagent 19429:9429 > /tmp/pf-vlagent.log 2>&1 &
echo $! > /tmp/pf-vlagent.pid
sleep 2; echo "vlagent forwarded to 127.0.0.1:19429"
