## Writes the seeds of every target as files, the starting corpus of libFuzzer: `mkcorpus <dir>` makes <dir>/<target>/seed-<n> and prints the names of the targets, one for each line.
## (tests/fuzz/targets.nim has the seeds; the same ones start the mutation fuzzer of tests/unit/tfuzz.nim.)
import std/os
import targets

let root = if paramCount() >= 1: paramStr(1) else: "build/fuzz/corpus"
for t in allTargets():
  let d = root / t.name
  createDir(d)
  for i, s in t.seeds: writeFile(d / ("seed-" & $i), s)
  echo t.name
