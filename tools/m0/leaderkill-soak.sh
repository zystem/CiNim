#!/bin/bash
# Repeats the leader-kill test N times; output to $2. Usage: leaderkill-soak.sh 20 /tmp/lk.log
export CINIM_RQLITE_URL=http://127.0.0.1:14001 CINIM_KUBECTL="kubectl --context admin@home -n rqlite"
cd "$(dirname "$0")/../.."
for n in $(seq $1); do
  echo "== run $n $(date +%T)"
  kubectl --context admin@home -n rqlite wait --for=condition=Ready pod --all --timeout=120s >/dev/null 2>&1
  tools/m0/pf-follower.sh
  ./build/tests/trqlite -- "7.2 leader killed*" 2>&1 | grep -E 'LOST|SUSPICIOUS|lost_acked|acked_writes|max_gap|leader_|FAILED|rror'
done
echo DONE
