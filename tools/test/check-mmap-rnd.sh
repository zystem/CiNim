#!/bin/sh
# Fails (exit 1, with the cure) when this machine cannot run an AddressSanitizer binary reliably: with vm.mmap_rnd_bits above 28 (32 on a 6.x kernel of Ubuntu 24.04; docs/specification.md,
# "An ASan run that crashes at start") a binary built with an old libasan (gcc 12 and the like) dies at start now and then and prints `AddressSanitizer:DEADLYSIGNAL` for ever. Run it before any
# ASan build is started (nimble testsan, tools/soak/run72.sh); the cure is `sysctl vm.mmap_rnd_bits=28` as root (/etc/sysctl.d/ to keep it).
# Where the value cannot be read (the file is root's only on some kernels) a program built with -fsanitize=address is started 12 times: one failure is an error.
f=${CHECK_MMAP_RND_FILE:-/proc/sys/vm/mmap_rnd_bits}      # the variable is for the test of this script
max=28
cure="the cure: sysctl vm.mmap_rnd_bits=$max as root (a file in /etc/sysctl.d/ keeps it after a restart)"
if [ -r "$f" ]; then
  v=$(cat "$f")
  if [ "$v" -gt "$max" ] 2>/dev/null; then
    echo "check-mmap-rnd: vm.mmap_rnd_bits is $v (more than $max): AddressSanitizer binaries crash at start now and then; $cure" >&2
    exit 1
  fi
  echo "check-mmap-rnd: vm.mmap_rnd_bits is $v: ok"
  exit 0
fi
cc=$(command -v cc || command -v gcc || command -v clang)
[ -n "$cc" ] || { echo "check-mmap-rnd: $f cannot be read and there is no C compiler to probe with: cannot tell; $cure" >&2; exit 1; }
d=$(mktemp -d) || exit 1
trap 'rm -rf "$d"' EXIT
printf 'int main(void) { return 0; }\n' > "$d/p.c"
"$cc" -fsanitize=address -o "$d/p" "$d/p.c" 2>"$d/err" || { echo "check-mmap-rnd: a program with -fsanitize=address cannot be built here: $(head -3 "$d/err")" >&2; exit 1; }
i=0
while [ $i -lt 12 ]; do
  "$d/p" >"$d/out" 2>&1; rc=$?
  if [ $rc -ne 0 ] || grep -q DEADLYSIGNAL "$d/out"; then
    echo "check-mmap-rnd: a test program built with -fsanitize=address failed at start (run $((i + 1)) of 12, exit $rc; $f cannot be read; vm.mmap_rnd_bits=32 is one cause, others: a limit of the address space (ulimit -v), a sandbox that forbids what ASan needs). Its output:" >&2
    head -c 1500 "$d/out" | head -12 >&2
    # shellcheck disable=SC3045
    echo "ulimit -v: $(ulimit -v), overcommit: $(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo unreadable), user: $(id -u); $cure" >&2
    exit 1
  fi
  i=$((i + 1))
done
echo "check-mmap-rnd: 12 starts of an ASan program, none crashed: ok"
