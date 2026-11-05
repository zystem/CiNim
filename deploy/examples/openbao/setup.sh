#!/bin/sh
# After init and unseal (README.md): the Transit engine, the key (derived=true: the core refuses one that is not), the policy of the core, a token of ten years, and the two Secrets that the core takes.
# BAO_TOKEN is the root token that `bao operator init` printed. NS and POD default to the shard's namespace and the first Pod of the chart. The two overrides are for trying the script
# outside a cluster: BAO_RUN is the command that runs `bao` ("docker exec -e ... bao-test bao"), KUBECTL a command that takes the place of kubectl.
set -eu
NS=${NS:-cinim-001}
POD=${POD:-openbao-0}
KUBECTL=${KUBECTL:-kubectl}
: "${BAO_TOKEN:?the root token that bao operator init printed}"
here=$(dirname "$0")
CLI=${CLI:-bao}      # `vault` for a Vault (with POD=vault-0): the same calls, its own command
bao() {
  if [ -n "${BAO_RUN:-}" ]; then $BAO_RUN "$@"; else $KUBECTL -n "$NS" exec -i "$POD" -- env BAO_TOKEN="$BAO_TOKEN" VAULT_TOKEN="$BAO_TOKEN" "$CLI" "$@"; fi
}
bao secrets enable transit
bao write -f transit/keys/cinim-shard type=aes256-gcm96 derived=true
bao policy write cinim-core - < "$here/policy.hcl"
# the token engine's limit is 32 days; a token cannot outlast it, and the core does not renew
bao write sys/auth/token/tune max_lease_ttl=87600h
token=$(bao token create -policy=cinim-core -orphan -no-default-policy -ttl=87600h -field=token)
$KUBECTL -n "$NS" create secret generic bao-token --from-literal=token="$token"
# the CA of the shard, as the core is to check OpenBao's certificate against it
ca=$($KUBECTL -n "$NS" get secret cinim-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)
$KUBECTL -n "$NS" create secret generic bao-ca --from-literal=ca.crt="$ca"
echo "done: the core takes bao-ca and bao-token (cinim-values.yaml)"
