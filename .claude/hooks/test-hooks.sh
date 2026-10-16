#!/bin/bash
# A check of the hooks of this directory: .claude/hooks/test-hooks.sh (exit code: the number of failures)
cd "$(dirname "$0")/../.." || exit 1
fails=0
# expect <name> <deny|ask|allow> <tool> <json of tool_input>
expect() {
  out=$(printf '{"tool_name":"%s","tool_input":%s}' "$3" "$4" | python3 .claude/hooks/guard.py 2>/dev/null); rc=$?
  got=allow; [ $rc = 2 ] && got=deny; [[ $out == *'"ask"'* ]] && got=ask
  if [ "$got" = "$2" ]; then echo "ok    $1 -> $got"; else echo "FAIL  $1: expected $2, got $got (rc $rc)"; fails=$((fails + 1)); fi
}
b() { python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
f() { python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1]}))' "$1"; }
expect "pkill -f"                         deny  Bash "$(b 'pkill -f nim')"
expect "pkill -9f"                        deny  Bash "$(b 'pkill -9f conductor')"
expect "after &&"                         deny  Bash "$(b 'cd x && pkill -f foo')"
expect "pkill -x"                         allow Bash "$(b 'pkill -x conductor')"
expect "pkill in a string"                allow Bash "$(b 'echo "never pkill -f"')"
expect "pkill in a here-document"         allow Bash "$(b $'cat > notes <<\'EOF\'\nrun pkill -f x\nand git push\nEOF')"
expect "pkill after a here-document"      deny  Bash "$(b $'cat <<EOF\ntext\nEOF\npkill -f x')"
expect "kubectl without a cluster"        deny  Bash "$(b 'kubectl get pods -A')"
expect "kubectl after a pipe"             deny  Bash "$(b 'echo x | kubectl apply -f -')"
expect "kubectl with --context"           allow Bash "$(b 'kubectl --context testing get pods')"
expect "kubectl with --kubeconfig"        allow Bash "$(b 'kubectl --kubeconfig /tmp/k get pods')"
expect "kubectl config"                   allow Bash "$(b 'kubectl config get-contexts')"
expect "grep for kubectl"                 allow Bash "$(b 'grep -rn kubectl src')"
expect "helm without a cluster"           deny  Bash "$(b 'helm upgrade x y')"
expect "helm template (no cluster)"       allow Bash "$(b 'helm template x deploy/charts/cinim-shard --set a=b')"
expect "helm list"                        deny  Bash "$(b 'helm list -A')"
expect "helm with --kube-context"         allow Bash "$(b 'helm --kube-context testing upgrade x y')"
expect "self-truncating python"           deny  Bash "$(b "python3 -c \"open(p,'w').write(open(p).read())\"")"
expect "python reading then writing"      allow Bash "$(b "python3 -c \"s=open(p).read(); open(p,'w').write(s)\"")"
expect "git commit"                       ask   Bash "$(b 'git commit -m x')"
expect "git push"                         ask   Bash "$(b 'cd x && git push origin main')"
expect "git -C dir commit"                ask   Bash "$(b 'git -C /tmp/x commit -m y')"
expect "git status"                       allow Bash "$(b 'git status --short')"
expect "git log mentioning commit"        allow Bash "$(b 'git log --grep=commit')"
expect "edit of a test key"               deny  Edit "$(f /home/z/CiNim/tests/certs/curve/core.key)"
expect "write of the docs-tr stamp"       deny  Write "$(f /home/z/CiNim/docs-tr/.sources.sha256)"
expect "edit in build/"                   deny  Edit "$(f /home/z/CiNim/build/nimproto/all.proto)"
expect "edit of a source"                 allow Edit "$(f /home/z/CiNim/src/core/api.nim)"
# the stop hook: the second stop in a row is let through
out=$(echo '{"stop_hook_active": true}' | python3 .claude/hooks/stop-check.py)
if [ -z "$out" ]; then echo "ok    stop hook lets a second stop through"; else echo "FAIL  stop hook looped"; fails=$((fails + 1)); fi
out=$(echo '{}' | python3 .claude/hooks/stop-check.py)
echo "info  stop hook now: ${out:-nothing to say}"
exit $fails
