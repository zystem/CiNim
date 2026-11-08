#!/bin/sh
# The checks of what no test compiles: the shell scripts (shellcheck), the Dockerfiles (hadolint) and the Helm charts (helm lint and helm template, then kubeconform on what was rendered).
#   tools/test/lint.sh                      all four, in this order
#   tools/test/lint.sh shell docker         the named ones (shell, docker, helm, kubeconform)
# POSIX sh and busybox tools only: the pipeline (.ci/pipeline.lua) runs each part in the image of its tool (shellcheck-alpine, hadolint, alpine/k8s, kubeconform), and none of them has bash.
# A tool that is not installed is a note and the part is skipped; with LINT_REQUIRE=1 (the pipeline sets it) it is a failure, so that a pipeline never passes by checking nothing.
# `helm` renders the charts into $LINT_RENDER (default build/lint-rendered) and `kubeconform` checks what is there, so the two can be in different images.
# Exit 0: nothing found. The findings are printed by the tools themselves.
#
# The bar: shellcheck at "warning" (no "info" or "style": 120 of them stand in the scripts, most of them quoting in one-off tools; raise the bar when they are gone);
# hadolint at "warning" (.hadolint.yaml says which rules are not followed, and why); helm lint --strict; every chart must render with the placeholder values below, and the output must be
# valid for the schemas of Kubernetes (a kind kubeconform has no schema for, the custom resources of cert-manager and the like, is skipped).
# File names must have no white space (the lists are read line by line).
set -u
cd "$(dirname "$0")/../.." || exit 1

status=0
fail() { echo "lint: FAILED: $*" >&2; status=1; }
have() {
  command -v "$1" >/dev/null && return 0
  if [ "${LINT_REQUIRE:-0}" = 1 ]; then fail "$1 is not installed (LINT_REQUIRE=1)"; else echo "lint: $1 is not installed: skipped" >&2; fi
  return 1
}
# the files of the working tree that git tracks, else the ones a find sees; $@ are the patterns of the names (a `case` pattern: * matches a slash too, as in a git pathspec)
tracked() {
  if git rev-parse --git-dir >/dev/null 2>&1; then git ls-files -- "$@"
  else
    find . \( -path ./build -o -path ./third_party -o -path ./docs-tr -o -path ./.git \) -prune -o -type f -print | sed 's#^\./##' | while read -r f; do
      # shellcheck disable=SC2254
      for pat in "$@"; do case $f in $pat) echo "$f"; break;; esac; done
    done
  fi
}
count() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

shell() {
  have shellcheck || return 0
  files=$(tracked '*.sh' | grep -v -e '^third_party/' -e '^docs-tr/')
  echo "lint: shellcheck: $(count "$files") scripts"
  printf '%s\n' "$files" | xargs shellcheck -S warning || fail "shellcheck"
}

dockerfiles() {
  have hadolint || return 0
  files=$(tracked 'Dockerfile*' '*/Dockerfile*' | grep -v -e '^third_party/' -e '^docs-tr/' | sort -u)
  echo "lint: hadolint: $(count "$files") Dockerfiles"
  printf '%s\n' "$files" | xargs hadolint --failure-threshold warning || fail "hadolint"
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

render=${LINT_RENDER:-build/lint-rendered}

helmcheck() {
  have helm || return 0
  mkdir -p "$render" && rm -f "$render"/*.yaml
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
    helm template "$name" "$c" $args >"$render/$name.yaml" 2>"$render/$name.err" || { head -20 "$render/$name.err" >&2; fail "helm template $name"; continue; }
    rm -f "$render/$name.err"
  done
}

kubeconform_check() {
  have kubeconform || return 0
  [ -n "$(ls "$render"/*.yaml 2>/dev/null)" ] || { fail "kubeconform: nothing rendered in $render (run the part helm first)"; return 0; }
  for f in "$render"/*.yaml; do
    echo "lint: kubeconform $(basename "$f" .yaml)"
    kubeconform -strict -ignore-missing-schemas -summary "$f" || fail "kubeconform $f"
  done
}

[ $# -gt 0 ] || set -- shell docker helm kubeconform
for w in "$@"; do
  case "$w" in
    shell)       shell ;;
    docker)      dockerfiles ;;
    helm)        helmcheck ;;
    kubeconform) kubeconform_check ;;
    *)           echo "usage: $0 [shell|docker|helm|kubeconform]..." >&2; exit 2 ;;
  esac
done
[ $status = 0 ] && echo "lint: ok"
exit $status
