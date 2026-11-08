#!/usr/bin/env bash
# The checks of what no test compiles: the shell scripts (shellcheck), the Dockerfiles (hadolint) and the Helm charts (helm lint, helm template, kubeconform).
#   tools/test/lint.sh                 all three
#   tools/test/lint.sh shell helm      the named ones (shell, docker, helm)
# A tool that is not installed is a note and the check is skipped; with LINT_REQUIRE=1 (the pipeline sets it) it is a failure, so that a pipeline never passes by checking nothing.
# Exit 0: nothing found. The findings are printed by the tools themselves.
#
# The bar: shellcheck at "warning" (no "info" or "style": 120 of them stand in the scripts, most of them quoting in one-off tools; raise the bar when they are gone);
# hadolint at "warning"; helm lint --strict; every chart must render with the placeholder values below, and the output must be valid for the schemas of Kubernetes (kubeconform;
# a kind it has no schema for, the custom resources of cert-manager and the like, is skipped).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(shell docker helm)
status=0
fail() { echo "lint: FAILED: $*" >&2; status=1; }
have() {
  command -v "$1" >/dev/null && return 0
  if [ "${LINT_REQUIRE:-0}" = 1 ]; then fail "$1 is not installed (LINT_REQUIRE=1)"; else echo "lint: $1 is not installed: skipped" >&2; fi
  return 1
}
tracked() {         # the files of the working tree that git tracks, else the ones a find sees; $@ are the patterns of the names
  if git rev-parse --git-dir >/dev/null 2>&1; then git ls-files -- "$@"
  else
    local names=() n
    for n in "$@"; do names+=(-o -name "$n"); done
    find . \( -path ./build -o -path ./third_party -o -path ./docs-tr -o -path ./.git \) -prune -o -type f \( "${names[@]:1}" \) -print | sed 's#^\./##'
  fi
}

shell() {
  have shellcheck || return 0
  mapfile -t files < <(tracked '*.sh' | grep -v -e '^third_party/' -e '^docs-tr/')
  echo "lint: shellcheck: ${#files[@]} scripts"
  shellcheck -S warning "${files[@]}" || fail "shellcheck"
}

dockerfiles() {
  have hadolint || return 0
  mapfile -t files < <(tracked 'Dockerfile*' '*/Dockerfile*' | grep -v -e '^third_party/' -e '^docs-tr/' | sort -u)
  echo "lint: hadolint: ${#files[@]} Dockerfiles"
  hadolint --failure-threshold warning "${files[@]}" || fail "hadolint"
}

# the values that let a chart render: what its schema and its guards ask for, as placeholders on a name that is reserved for examples (.test) and not any name of ours
chart_args() {
  case "$1" in
    cinim-shard)   echo "-n cinim-001 --set domain=example.test --set image.repository=registry.example.test/cinim" ;;
    cinim-router)  echo "--set domain=example.test --set routerKey=0123456789abcdef0123 --set image.repository=registry.example.test/router" ;;
    cinim-storage) echo "--set image.repository=registry.example.test/storage --set secrets.existingSecret=lint --set secrets.sealKey=0123456789abcdef0123" ;;
    *)             echo "" ;;
  esac
}

helmcheck() {
  have helm || return 0
  local c name args rendered kc=0
  have kubeconform && kc=1
  for c in deploy/charts/*/; do
    c=${c%/}; name=$(basename "$c")
    if [ -f "$c/Chart.lock" ] && [ ! -d "$c/charts" ]; then
      echo "lint: helm dependency build $name"
      helm dependency build "$c" >/dev/null || { fail "helm dependency build $name"; continue; }
    fi
    args=$(chart_args "$name")
    echo "lint: helm lint --strict $name"
    # shellcheck disable=SC2086
    helm lint --strict "$c" $args >/dev/null || { helm lint --strict "$c" $args >&2; fail "helm lint $name"; continue; }
    # shellcheck disable=SC2086
    if ! rendered=$(helm template "$name" "$c" $args 2>&1); then echo "$rendered" | head -20 >&2; fail "helm template $name"; continue; fi
    if [ $kc = 1 ]; then
      echo "lint: kubeconform $name"
      printf '%s\n' "$rendered" | kubeconform -strict -ignore-missing-schemas -summary - || fail "kubeconform $name"
    fi
  done
}

for w in "${want[@]}"; do
  case "$w" in
    shell)  shell ;;
    docker) dockerfiles ;;
    helm)   helmcheck ;;
    *)      echo "usage: $0 [shell|docker|helm]..." >&2; exit 2 ;;
  esac
done
[ $status = 0 ] && echo "lint: ok"
exit $status
