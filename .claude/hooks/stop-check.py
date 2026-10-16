#!/usr/bin/env python3
"""Stop hook: before Claude ends its answer, three things CLAUDE.md asks for are looked at, and if one is not in order Claude is sent back once to do it.
  * docs/ changed in the working tree and docs-tr/ (the owner's gitignored Russian mirror, when it exists on this machine) is out of date: update it, then `docs-tr/check.sh --stamp`;
  * proto/ changed and build/nimproto is older: `tools/proto/nim_flatten.sh build/nimproto`;
  * a tracked file is empty in the working tree (a tool that wrote a file from itself truncates it): look at `git diff --stat` before going on.
Nothing is checked after a commit (the working tree is then the same as HEAD), and a second stop in a row is let through, so it cannot loop."""
import json
import os
import subprocess
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
if data.get("stop_hook_active"):
    sys.exit(0)
root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
os.chdir(root)


def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None


changed = run("git", "diff", "HEAD", "--name-only")
if changed is None or changed.returncode != 0:
    sys.exit(0)
names = [n for n in changed.stdout.splitlines() if n]
problems = []

if any(n.startswith("docs/") for n in names) and os.path.exists("docs-tr/check.sh"):
    r = run("docs-tr/check.sh")
    if r is not None and r.returncode != 0:
        problems.append("docs/ changed and docs-tr/ is out of date:\n%s\nUpdate the Russian mirror, then run `docs-tr/check.sh --stamp`." % r.stdout.strip())

if any(n.startswith("proto/") for n in names):
    flat = "build/nimproto/all.proto"
    newest = 0.0
    for n in names:
        if n.startswith("proto/") and os.path.exists(n):
            newest = max(newest, os.path.getmtime(n))
    if not os.path.exists(flat) or os.path.getmtime(flat) < newest:
        problems.append("proto/ changed and build/nimproto is older: run `tools/proto/nim_flatten.sh build/nimproto`.")

empty = [n for n in names if os.path.isfile(n) and os.path.getsize(n) == 0]
if empty:
    problems.append("tracked files are empty in the working tree (truncated?): " + ", ".join(empty[:10]) + ". Check `git diff --stat`.")

if problems:
    print(json.dumps({"decision": "block", "reason": "Before you finish (CLAUDE.md):\n- " + "\n- ".join(problems)}))
sys.exit(0)
