#!/bin/bash
# Port-forward localhost:19429 to vlagent's own insert endpoint (/insert/jsonline etc, port 9429).
K="kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT} -n victorialogs"
[ -f /tmp/pf-vlagent.pid ] && kill "$(cat /tmp/pf-vlagent.pid)" 2>/dev/null; sleep 1
. "$(dirname "$0")/../test/portfree.sh"
require_free_port 19429 "pf-vlagent"      # not ours any more after the kill above: another process holds it
nohup $K port-forward svc/vlagent 19429:9429 > /tmp/pf-vlagent.log 2>&1 &
echo $! > /tmp/pf-vlagent.pid
sleep 2; echo "vlagent forwarded to 127.0.0.1:19429"
