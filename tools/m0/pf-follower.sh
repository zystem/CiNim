#!/bin/bash
# Port-forward localhost:14001 to a rqlite FOLLOWER (the leader-kill test kills the leader).
K="kubectl --context admin@home -n rqlite"
[ -f /tmp/pf.pid ] && kill $(cat /tmp/pf.pid) 2>/dev/null; sleep 1
for p in rqlite-0 rqlite-1 rqlite-2; do
  L=$($K exec $p -- wget -qO- localhost:4001/nodes 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print([k for k,v in d.items() if v.get('leader')][0])" 2>/dev/null) && break
done
for p in rqlite-0 rqlite-1 rqlite-2; do [ "$p" != "$L" ] && F=$p && break; done
nohup $K port-forward pod/$F 14001:4001 > /tmp/pf.log 2>&1 &
echo $! > /tmp/pf.pid
sleep 3; echo "leader=$L forward=$F"
