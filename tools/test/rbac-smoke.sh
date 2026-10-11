#!/bin/bash
# A check of the basic RBAC (IAM-001, D-50) against a running core, with what the core wrote to its log at the first start:
#   tools/test/rbac-smoke.sh <base url, e.g. http://127.0.0.1:28082> <file with the log of the core, or - for the standard input>
#   kubectl -n cinim-001 logs deploy/cinim-core | tools/test/rbac-smoke.sh http://127.0.0.1:28082 -
# It reads the lines `cinim-credentials user=... role=... password=... token=...`, logs in with each password, and asks routes of every kind with each token.
# It changes nothing (a request that would change something is sent with a body that is refused, or for a thing that does not exist). Exit code: the number of failures.
base=${1:?base url}; src=${2:--}
declare -A TOKEN PASS
while read -r line; do
  [[ $line == cinim-credentials\ * ]] || continue
  declare -A kv=(); for kvp in $line; do [[ $kvp == *=* ]] && kv[${kvp%%=*}]=${kvp#*=}; done
  TOKEN[${kv[user]}]=${kv[token]}; PASS[${kv[user]}]=${kv[password]}
done < <(cat "$src")
fails=0
check() {   # what, expected, got
  if [ "$2" = "$3" ]; then echo "ok    $1 -> $3"; else echo "FAIL  $1: expected $2, got $3"; fails=$((fails + 1)); fi
}
code() {   # token method path [body]
  curl -s -o /dev/null -w '%{http_code}' -X "$2" "$base$3" ${1:+-H "Authorization: Bearer $1"} ${4:+-H 'Content-Type: application/json' -d "$4"}
}
for u in admin rw ro; do [ -n "${TOKEN[$u]:-}" ] || { echo "FAIL  no credentials line for $u in the log"; exit 1; }; done
check "no token: components" 401 "$(code '' GET /api/v1/components)"
check "a made-up token: components" 401 "$(code cnm_000000000000_$(printf '0%.0s' {1..64}) GET /api/v1/components)"
rows=(
  "GET /api/v1/users||200 403 403"
  "GET /api/v1/tokens||200 403 403"
  "GET /api/v1/storage||200 403 403"
  "GET /api/v1/components||200 200 200"
  "GET /api/v1/launch-gate||200 200 200"
  "GET /api/v1/organizations||200 200 200"
  "POST /api/v1/runs|{}|400 400 403"
  "DELETE /api/v1/organizations/no-such-org||404 403 403"
  "PUT /api/v1/users/ro/password|{\"password\":\"too short\"}|400 403 400"
  "PUT /api/v1/users/rw/password|{\"password\":\"too short\"}|400 400 403"
  "PUT /api/v1/users/admin/password|{\"password\":\"too short\"}|400 403 403"
)
for row in "${rows[@]}"; do
  IFS='|' read -r mp body exp <<<"$row"; read -r m p <<<"$mp"; read -r ea er eo <<<"$exp"
  i=0; for u in admin rw ro; do e=(${ea} ${er} ${eo}); check "$u $m $p" "${e[$i]}" "$(code "${TOKEN[$u]}" "$m" "$p" "$body")"; i=$((i + 1)); done
done
for u in admin rw ro; do
  t=$(curl -s -X POST "$base/api/v1/login" -d "{\"user\":\"$u\",\"password\":\"${PASS[$u]}\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  check "login $u gives a token that works" 200 "$(code "$t" GET /api/v1/components)"
  check "login $u: the token of the login has the rights of $u" "$([ $u = admin ] && echo 200 || echo 403)" "$(code "$t" GET /api/v1/users)"
done
check "login with a wrong password" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/api/v1/login" -d '{"user":"rw","password":"wrong"}')"
check "login of a user that does not exist" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/api/v1/login" -d '{"user":"nobody","password":"x"}')"
echo "$fails failures"
exit $fails
