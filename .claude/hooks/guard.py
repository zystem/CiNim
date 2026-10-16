#!/usr/bin/env python3
"""PreToolUse guard for the rules of CLAUDE.md that cost time when forgotten. Reads the hook JSON on stdin.

Bash: refuses `pkill -f`, a `kubectl` or `helm` call that names no cluster (the current context switched to another cluster once and the commands ran there), and the self-truncating
`open(p,'w').write(open(p).read())`; asks the owner before `git commit` and `git push` (commit and push only when asked).
Edit and Write: refuses the keys of tests/certs, the stamp of docs-tr (made by `docs-tr/check.sh --stamp`) and the generated build/ directory.
Refusing is exit 2 with the reason on stderr (Claude sees it); asking is a JSON answer with permissionDecision "ask"."""
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
tool = data.get("tool_name", "")
inp = data.get("tool_input") or {}


def deny(why):
    sys.stderr.write("blocked by .claude/hooks/guard.py: " + why + "\n")
    sys.exit(2)


def ask(why):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": why}}))
    sys.exit(0)


if tool == "Bash":
    cmd = inp.get("command", "")
    # the text of a here-document is data (a file being written), not commands
    cmd = re.sub(r"(<<-?\s*(['\"]?)(\w+)\2[^\n]*)\n.*?\n\s*\3\b", r"\1", cmd, flags=re.DOTALL)
    # a command word: at the start, or after ; & | ( or $( , possibly behind VAR=value assignments or env/sudo
    word = r"(?:^|[;&|(\n]|\$\()\s*(?:(?:\w+=\S*|env|sudo)\s+)*"
    if re.search(word + r"pkill\s+(?:\S+\s+)*?-\w*f", cmd) or re.search(word + r"pkill\s+--full\b", cmd):
        deny("never `pkill -f` (CLAUDE.md): it matches whole command lines, the shell that runs the command included. Use `pkill -x name` or a PID.")
    for tool_name, flags in (("kubectl", ("--context", "--kubeconfig")), ("helm", ("--kube-context", "--kubeconfig"))):
        if re.search(word + tool_name + r"\s", cmd) and not any(f in cmd for f in flags):
            if tool_name == "kubectl" and re.search(word + r"kubectl\s+(config|version\s+--client|completion|help)\b", cmd):
                continue
            if tool_name == "helm" and re.search(word + r"helm\s+(template|lint|package|show|version|repo|search|dependency|create|completion|help)\b", cmd):
                continue                                    # these do not talk to a cluster
            deny("`%s` without %s: the current context has switched to another cluster before and the commands ran there. Name the cluster in the command." % (tool_name, " or ".join(flags)))
    if re.search(r"open\(\s*(\w+)[^)]*['\"]w['\"]\s*\)\s*\.write\(\s*open\(\s*\1\b", cmd):
        deny("`open(p,'w').write(open(p).read())` truncates the file before it is read (CLAUDE.md). Read first, then write.")
    if re.search(word + r"git\s+(?:-[Cc]\s+\S+\s+|-\S+\s+)*(commit|push)\b", cmd):
        ask("CLAUDE.md: commit and push only when the owner asks. Allow only if they did.")
elif tool in ("Edit", "Write", "NotebookEdit"):
    path = inp.get("file_path", "") or inp.get("notebook_path", "")
    if "/tests/certs/" in path:
        deny("tests/certs holds the keys of the tests; they are made by the setup, not edited by hand.")
    if path.endswith("/docs-tr/.sources.sha256"):
        deny("docs-tr/.sources.sha256 is written by `docs-tr/check.sh --stamp` after the translation is brought up to date.")
    if "/build/" in path:
        deny("build/ is generated (nimproto, binaries, test outputs); change the source and build again.")
sys.exit(0)
