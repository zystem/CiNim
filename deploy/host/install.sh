#!/bin/bash
# Installs the long-test host's units (deploy/host/*.service) on root@HOST and starts them.
# Usage: install.sh root@HOST
# The host needs /opt/cinim/core (tools/shim/build_static.sh build/core-static src/core/main.nim "" 0),
# /opt/cinim/certs/curve/{core.pub,core.key,client.pub}, kubectl, and /root/.kube/config pointing at the test cluster
# (its current context is the one the port-forwards use).
# core reaches rqlite/VictoriaLogs through kubectl port-forwards on the host itself, so nothing depends on
# the developer machine being awake.
set -euo pipefail
cd "$(dirname "$0")"
HOST="${1:?usage: install.sh root@HOST}"
scp -q cinim-*.service "$HOST:/etc/systemd/system/"
ssh "$HOST" 'systemctl daemon-reload && systemctl enable --now cinim-pf-rqlite cinim-pf-vlagent cinim-pf-victorialogs && systemctl restart cinim-core && systemctl enable cinim-core && sleep 3 && systemctl is-active cinim-pf-rqlite cinim-pf-vlagent cinim-pf-victorialogs cinim-core'
