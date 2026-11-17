#!/bin/sh
# Makes cinim.lock again from cinim.nimble: the exact version and commit of every nimble package, so that two builds of one commit of ours use the same code. Run it after a change of a
# `requires` line (or `--refresh` as the first argument: `tools/deps/lock.sh --refresh` moves every package to the newest version the requirements allow), read the diff, and commit the lock with
# cinim.nimble. `tests/unit/trepository.nim` fails when the lock does not satisfy cinim.nimble.
# The file is called cinim.lock and not nimble.lock: a nimble.lock in the directory makes plain `nim c` fail to find the packages ("cannot open file: checksums/sha2", found 2026-11-18), so the
# builds that want it name it (`nimble install --lockFile=cinim.lock`, the Dockerfiles). On a workstation: `nimble install -d --lockFile=cinim.lock`.
# `nimble lock` also makes `nimble.paths`, writes `--noNimblePath` and an include into config.nims and adds three lines to .gitignore: that would stop every build, so the two files are put back
# as they were and nimble.paths is removed.
set -eu
cd "$(dirname "$0")/../.."
keep=$(mktemp -d)
cp config.nims .gitignore "$keep/"
trap 'cp "$keep/config.nims" config.nims; cp "$keep/.gitignore" .gitignore; rm -f nimble.paths; rm -rf "$keep"' EXIT
nimble lock --lockFile=cinim.lock "$@"
