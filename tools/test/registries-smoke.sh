#!/bin/sh
# A check of the registries of an organisation (D-114) against a running core, as an administrator would do it:
#   TOKEN=<an API token with registry.write in the organisation> tools/test/registries-smoke.sh <base url, e.g. http://127.0.0.1:28082> <organisation slug>
# The token is read from the environment (never from the command line, never printed). It makes the registry `smoke-reg`, reads it, changes it, checks that the password is in no answer and in
# no list, removes it, and asks what must be refused. It changes nothing else, and removes what it made also when it fails. Exit code: the number of failures.
base=${1:?base url}; org=${2:?organisation slug}; : "${TOKEN:?the API token in TOKEN}"
api="$base/api/v1/organizations/$org/registries"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1 -> $3"; else echo "FAIL  $1: expected $2, got $3"; fails=$((fails + 1)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN" ${3:+-H 'Content-Type: application/json' -d "$3"} "$2"; }
body() { curl -s -X "$1" -H "Authorization: Bearer $TOKEN" ${3:+-H 'Content-Type: application/json' -d "$3"} "$2"; }
trap 'code DELETE "$api/smoke-reg" >/dev/null' EXIT
code DELETE "$api/smoke-reg" >/dev/null
secret="smoke-pw-$$-$(date +%s)"

check "no token: list" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$api")"
check "make a registry" 201 "$(code PUT "$api/smoke-reg" "{\"address\":\"ghcr.io/smoke\",\"username\":\"smoke\",\"password\":\"$secret\",\"description\":\"made by the smoke test\"}")"
check "change it (no password given: the login stays)" 200 "$(code PUT "$api/smoke-reg" '{"insecure":true}')"
one=$(body GET "$api/smoke-reg")
case $one in *'"has_password":true'*'"insecure":true'*|*'"insecure":true'*'"has_password":true'*) check "the registry has a login and is plain HTTP" yes yes;; *) check "the registry has a login and is plain HTTP" yes "no: $one";; esac
check "the list names it" 1 "$(body GET "$api" | grep -c '"smoke-reg"')"
case "$one$(body GET "$api")$(body PUT "$api/smoke-reg" '{"description":"again"}')" in *"$secret"*) check "the password is in no answer" nowhere "in an answer";; *) check "the password is in no answer" nowhere nowhere;; esac
check "a bad name" 400 "$(code PUT "$api/Bad%20Name" '{"address":"ghcr.io"}')"
check "an address with a scheme" 400 "$(code PUT "$api/smoke-reg" '{"address":"https://ghcr.io/x"}')"
check "a password with no user" 400 "$(code PUT "$api/smoke-none" '{"address":"ghcr.io","password":"x"}')"
check "a registry that is not there" 404 "$(code GET "$api/smoke-none")"
check "an organisation that is not there" 404 "$(code GET "$base/api/v1/organizations/no-such-org-smoke/registries")"
check "take the login away" 200 "$(code PUT "$api/smoke-reg" '{"username":"","password":""}')"
case $(body GET "$api/smoke-reg") in *'"has_password":false'*) check "no login now" yes yes;; *) check "no login now" yes no;; esac
check "remove it" 200 "$(code DELETE "$api/smoke-reg")"
check "remove it again" 404 "$(code DELETE "$api/smoke-reg")"
echo "$fails failures"
exit $fails
