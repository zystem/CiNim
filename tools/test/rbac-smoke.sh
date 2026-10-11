#!/bin/bash
# A check of the basic RBAC (IAM-001, D-50) against a running core, as an administrator would do it:
#   tools/test/rbac-smoke.sh <base url, e.g. http://127.0.0.1:28082> <file with the log of the core, or - for the standard input>
#   kubectl -n cinim-001 logs deploy/cinim-core | tools/test/rbac-smoke.sh http://127.0.0.1:28082 -
# The administrator is the user `admin` of the first start: its line `cinim-credentials user=admin ... password=... token=...` is in the log. Its password has to be changed
# before anything else is allowed; if that has not been done yet, the script checks that, and changes it to $ADMIN_NEW_PASSWORD (or to a random one, which it prints once).
# If it has been done, give the current password in $ADMIN_PASSWORD. Then, under the administrator, it makes the users smoke-rw, smoke-dev and smoke-ro, asks routes of every
# kind with each of them, and deletes them (also when it fails). It changes nothing else. Exit code: the number of failures.
# Through `kubectl port-forward` set ON_DROP to the command that starts the forward again.
base=${1:?base url}; src=${2:--}
LOGPW=; LOGTOKEN=
while read -r line; do
  [[ $line == cinim-credentials\ user=admin\ * ]] || continue
  for kvp in $line; do case $kvp in password=*) LOGPW=${kvp#password=};; token=*) LOGTOKEN=${kvp#token=};; esac; done
done < <(cat "$src")
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1 -> $3"; else echo "FAIL  $1: expected $2, got $3"; fails=$((fails + 1)); fi; }
retried=0
ON_DROP=${ON_DROP:-}   # a command to run when a connection was dropped (e.g. to start a `kubectl port-forward` again, which does not survive it)
# curl, and again (up to 5 times) when the connection was dropped before any answer (code 000): after a number of requests with a body the HTTP layer of the core drops the next
# connections now and then (a known defect of the server library, not of RBAC); a refusal of the request has a status, so it is never retried. The retries are counted and shown.
curlr() {
  local out i
  for i in 1 2 3 4 5; do
    out=$(curl -s "$@"); [ "$out" != 000 ] && break
    retried=$((retried + 1)); [ -z "$ON_DROP" ] || eval "$ON_DROP" >/dev/null 2>&1; sleep 0.3
  done
  echo -n "$out"
}
code() {   # token method path [body]
  curlr -o /dev/null -w '%{http_code}' -X "$2" "$base$3" ${1:+-H "Authorization: Bearer $1"} ${4:+-H 'Content-Type: application/json' -d "$4"}
}
status() { curlr -o /dev/null -w '%{http_code}' "$@"; }
field() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
rand() { head -c 18 /dev/urandom | base64 | tr '+/' 'Aa' | tr -d '=\n'; echo -n "x9"; }
login() {
  local out i
  for i in 1 2 3 4 5; do
    out=$(curl -s -X POST "$base/api/v1/login" -d "{\"user\":\"$1\",\"password\":\"$2\"}"); [ -n "$out" ] && break
    retried=$((retried + 1)); [ -z "$ON_DROP" ] || eval "$ON_DROP" >/dev/null 2>&1; sleep 0.3
  done
  echo -n "$out"
}
declare -A TOKEN PASS

# --- the administrator
check "no token: components" 401 "$(code '' GET /api/v1/components)"
check "a made-up token: components" 401 "$(code cnm_000000000000_$(printf '0%.0s' {1..64}) GET /api/v1/components)"
ADMINPW=${ADMIN_PASSWORD:-}
if [ -z "$ADMINPW" ]; then
  [ -n "$LOGPW" ] || { echo "FAIL  no administrator line in the log, and no ADMIN_PASSWORD"; exit 1; }
  resp=$(login admin "$LOGPW")
  if [[ $resp == *'"password_change_required":true'* ]]; then
    echo "ok    admin logs in with the password of the log, and is told to change it"
    t=$(echo "$resp" | field token)
    check "admin before the change: users (login token)" 403 "$(code "$t" GET /api/v1/users)"
    check "admin before the change: users (token of the log)" 403 "$(code "$LOGTOKEN" GET /api/v1/users)"
    check "admin before the change: runs" 403 "$(code "$t" GET /api/v1/runs/x)"
    NEWPW=${ADMIN_NEW_PASSWORD:-$(rand)}
    check "admin changes the password" 200 "$(code "$t" PUT /api/v1/users/admin/password "{\"current_password\":\"$LOGPW\",\"password\":\"$NEWPW\"}")"
    ADMINPW=$NEWPW
    [ -n "${ADMIN_NEW_PASSWORD:-}" ] || echo "note  the password of admin is now: $NEWPW"
  else
    echo "FAIL  the password of the log does not work (changed already?): give the current one in ADMIN_PASSWORD"; exit 1
  fi
fi
ADMIN=$(login admin "$ADMINPW" | field token)
[ -n "$ADMIN" ] || { echo "FAIL  admin cannot log in"; exit 1; }
check "admin after the change: users" 200 "$(code "$ADMIN" GET /api/v1/users)"
check "admin: roles" 200 "$(code "$ADMIN" GET /api/v1/roles)"

# --- the users, made by the administrator
cleanup() { for u in rw dev ro; do code "$ADMIN" DELETE "/api/v1/users/smoke-$u" >/dev/null; done; }
trap cleanup EXIT
cleanup
for u in rw dev ro; do
  PASS[$u]=$(rand)
  check "admin makes smoke-$u ($u)" 201 "$(code "$ADMIN" POST /api/v1/users "{\"name\":\"smoke-$u\",\"role\":\"$u\",\"password\":\"${PASS[$u]}\"}")"
  r=$(login "smoke-$u" "${PASS[$u]}")
  TOKEN[$u]=$(echo "$r" | field token)
  [[ $r == *'"password_change_required":false'* ]] || { echo "FAIL  smoke-$u is asked to change the password"; fails=$((fails + 1)); }
done
TOKEN[admin]=$ADMIN
check "a made user with a short password" 400 "$(code "$ADMIN" POST /api/v1/users '{"name":"smoke-x","role":"ro","password":"short"}')"
check "a made user with a role that does not exist" 400 "$(code "$ADMIN" POST /api/v1/users "{\"name\":\"smoke-x\",\"role\":\"root\",\"password\":\"$(rand)\"}")"
check "a made user with a simple password" 400 "$(code "$ADMIN" POST /api/v1/users '{"name":"smoke-x","role":"ro","password":"1111111111111111"}')"
check "a user that exists" 409 "$(code "$ADMIN" POST /api/v1/users "{\"name\":\"smoke-ro\",\"role\":\"ro\",\"password\":\"$(rand)\"}")"

#        method path|body|admin rw dev ro
rows=(
  "GET /api/v1/users||200 403 403 403"
  "GET /api/v1/roles||200 403 403 403"
  "GET /api/v1/tokens||200 403 403 403"
  "GET /api/v1/storage||200 403 403 403"
  "GET /api/v1/components||200 200 200 200"
  "GET /api/v1/launch-gate||200 200 200 200"
  "GET /api/v1/organizations||200 200 200 200"
  "POST /api/v1/runs|{}|400 400 400 403"
  "DELETE /api/v1/runs/no-such-run||404 404 403 403"
  "POST /api/v1/runs/no-such-run:cancel||404 404 403 403"
  "DELETE /api/v1/organizations/no-such-org||404 403 403 403"
  "POST /api/v1/users|{}|400 403 403 403"
  "DELETE /api/v1/users/admin||403 403 403 403"
  "DELETE /api/v1/users/no-such-user||404 403 403 403"
  "PUT /api/v1/users/smoke-ro/password|{\"password\":\"too short\"}|400 403 403 400"
  "PUT /api/v1/users/smoke-dev/password|{\"password\":\"too short\"}|400 403 400 403"
  "PUT /api/v1/users/smoke-rw/password|{\"password\":\"too short\"}|400 400 403 403"
)
for row in "${rows[@]}"; do
  IFS='|' read -r mp body exp <<<"$row"; read -r m p <<<"$mp"; e=($exp); i=0
  for u in admin rw dev ro; do check "$u $m $p" "${e[$i]}" "$(code "${TOKEN[$u]}" "$m" "$p" "$body")"; i=$((i + 1)); done
done
# a user's own password: the current one is asked for, and the new one must differ
check "rw changes its password without the current one" 403 "$(code "${TOKEN[rw]}" PUT /api/v1/users/smoke-rw/password "{\"password\":\"$(rand)\"}")"
check "rw changes its password with a wrong current one" 403 "$(code "${TOKEN[rw]}" PUT /api/v1/users/smoke-rw/password "{\"current_password\":\"nope\",\"password\":\"$(rand)\"}")"
check "rw changes its password to the same" 400 "$(code "${TOKEN[rw]}" PUT /api/v1/users/smoke-rw/password "{\"current_password\":\"${PASS[rw]}\",\"password\":\"${PASS[rw]}\"}")"
NEW=$(rand)
check "rw changes its password" 200 "$(code "${TOKEN[rw]}" PUT /api/v1/users/smoke-rw/password "{\"current_password\":\"${PASS[rw]}\",\"password\":\"$NEW\"}")"
check "rw logs in with the new password" 200 "$(status -X POST "$base/api/v1/login" -d "{\"user\":\"smoke-rw\",\"password\":\"$NEW\"}")"
check "rw logs in with the old password" 401 "$(status -X POST "$base/api/v1/login" -d "{\"user\":\"smoke-rw\",\"password\":\"${PASS[rw]}\"}")"
NEW2=$(rand)
check "admin changes the password of smoke-dev (no current one)" 200 "$(code "$ADMIN" PUT /api/v1/users/smoke-dev/password "{\"password\":\"$NEW2\"}")"
check "dev logs in with it" 200 "$(status -X POST "$base/api/v1/login" -d "{\"user\":\"smoke-dev\",\"password\":\"$NEW2\"}")"
check "login with a wrong password" 401 "$(status -X POST "$base/api/v1/login" -d '{"user":"smoke-ro","password":"wrong"}')"
check "login of a user that does not exist" 401 "$(status -X POST "$base/api/v1/login" -d '{"user":"nobody","password":"x"}')"
check "a deleted user's token stops working" 401 "$(code "$ADMIN" DELETE /api/v1/users/smoke-ro >/dev/null; code "${TOKEN[ro]}" GET /api/v1/components)"
[ $retried -eq 0 ] || echo "note  $retried request(s) were sent again because the core dropped the connection before answering"
echo "$fails failures"
exit $fails
