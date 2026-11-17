#!/bin/sh
# Coverage-guided fuzzing (libFuzzer with clang and AddressSanitizer) of the parsers of tests/fuzz/targets.nim (SEC-009): the BER of the directory, the security-key data, the frames of the push
# channel and of the run pipe, the Protobuf of the peers. The same targets run as a plain mutation fuzzer in the ordinary suite (tests/unit/tfuzz.nim); this one finds what is behind a
# comparison that a blind mutation does not pass.
#   tools/test/fuzz.sh [SECONDS [TARGET...]]       SECONDS for each target (default 60); no target: all of them
# needs clang (CLANG, default clang-18, with its libFuzzer runtime: the packages clang-18 and libclang-rt-18-dev of Ubuntu), nim, and vm.mmap_rnd_bits 28 or less (tools/test/check-mmap-rnd.sh).
# A find (a crash, a sanitizer report, a timeout) is saved as build/fuzz/crash-<target>-<hash>: copy it to tests/fuzz/regressions/<target>/ so that tests/unit/tfuzz.nim keeps it. Exit 1 when there was one.
set -eu
cd "$(dirname "$0")/../.."
secs=${1:-60}; [ $# -gt 0 ] && shift
clang=${CLANG:-clang-18}
command -v "$clang" >/dev/null || { echo "fuzz: $clang is not installed (apt install clang-18 libclang-rt-18-dev)" >&2; exit 2; }
sh tools/test/check-mmap-rnd.sh
[ -f build/nimproto/protos.nim ] || tools/proto/nim_flatten.sh build/nimproto >/dev/null
out=build/fuzz
mkdir -p "$out"
flags="--hints:off --warnings:off -p:src"
echo "fuzz: building the harness with $clang"
nim c $flags --cc:clang --clang.exe:"$clang" --clang.linkerexe:"$clang" -d:release -d:useMalloc -d:noSignalHandler --noMain:on --stackTrace:off \
  --passC:-fsanitize=fuzzer-no-link,address --passL:-fsanitize=fuzzer,address --nimcache:"$out/nimcache-harness" -o:"$out/harness" tests/fuzz/harness.nim
nim c $flags --nimcache:"$out/nimcache-corpus" -o:"$out/mkcorpus" tests/fuzz/mkcorpus.nim
targets=$("$out/mkcorpus" "$out/corpus")
[ $# -gt 0 ] && targets="$*"
bad=0
for t in $targets; do
  echo "== fuzz $t ($secs s)"
  mkdir -p "tests/fuzz/regressions/$t"
  if FUZZ_TARGET=$t ASAN_OPTIONS=detect_leaks=0 "$out/harness" -max_total_time="$secs" -timeout=10 -rss_limit_mb=2048 -print_final_stats=1 \
       -artifact_prefix="$out/crash-$t-" "$out/corpus/$t" "tests/fuzz/regressions/$t" 2>&1 | tail -n 12; then
    :
  fi
  # `tail` hides the status of the harness: a find leaves its artifact
  if ls "$out"/crash-"$t"-* >/dev/null 2>&1; then echo "fuzz: FOUND something in $t: $(ls "$out"/crash-"$t"-*)"; bad=1; fi
done
[ "$bad" = 0 ] && echo "fuzz: no find in $secs s for each of the targets" || { echo "fuzz: finds are in $out/crash-*" >&2; exit 1; }
