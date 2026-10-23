## D-81: the components of src/ are directories, and what each may import is written down and checked here: the shim, the job controller, the storage module, the UI and the executor import
## `common` and nothing else of ours; the conductor and the core import `common` and `executor`; the router imports `common` and `ui`; `common` imports none. Nobody imports `core` but the core.
## The picture came out of the code on 2026-10-23 and this test keeps it from being lost by an `import` that is easy to write: a shim that reads a module of the core would pull the core into every
## step Pod, and the pipeline (`plan` in .ci/pipeline.lua, D-82) builds and tests by this graph: its table is checked against this one.
import std/[unittest, os, strutils, sequtils, algorithm, sets, tables]

const components = ["common", "shim", "jobcontroller", "conductor", "executor", "core", "storage", "ui", "router"]

let allowed = {
  "common": @[],
  "shim": @["common"], "jobcontroller": @["common"], "storage": @["common"], "ui": @["common"], "executor": @["common"],
  "conductor": @["common", "executor"], "core": @["common", "executor"], "router": @["common", "ui"]}.toTable

proc importedComponents*(text: string): HashSet[string] =
  ## the components that the import, from, include and export statements of a module name, as `a/b`, `../a/b`, `a/[b, c]` (a statement goes on while a bracket is open or a line ends with a comma)
  var inStatement = false
  var open = 0
  for raw in text.splitLines:
    var line = raw
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    let t = line.strip
    if not inStatement:
      for kw in ["import ", "from ", "include ", "export "]:
        if t.startsWith(kw): inStatement = true
    if not inStatement: continue
    for c in components:
      var at = 0
      while true:
        let i = line.find(c & "/", at)
        if i < 0: break
        if i == 0 or line[i - 1] notin IdentChars: result.incl c
        at = i + 1
    open += line.count('[') - line.count(']')
    if open <= 0 and not t.endsWith(","):
      inStatement = false
      open = 0

proc moduleFiles(component: string): seq[string] =
  for f in walkDirRec(currentSourcePath().parentDir.parentDir.parentDir / "src" / component):
    if f.endsWith(".nim"): result.add f

suite "D-81 what a statement of import names":
  test "the forms of a path, and not the words that only look like one":
    check importedComponents("import ../common/rqlite") == ["common"].toHashSet
    check importedComponents("import common/[rqlite, ids]\nimport std/[os]") == ["common"].toHashSet
    check importedComponents("import std/[json, os]\nimport protobuf_serialization/files/type_generator") == initHashSet[string]()
    check importedComponents("from ../core/api import x\nexport ../ui/app") == ["core", "ui"].toHashSet
    check importedComponents("import a/[b,\n  common/c,\n  storage/d]\nlet x = 1") == ["common", "storage"].toHashSet
    check importedComponents("import schema, scheduler # core/scheduler is meant\nlet y = \"core/x\"") == initHashSet[string]()
    check importedComponents("when defined(x):\n  import ../shim/logclient") == ["shim"].toHashSet
    check importedComponents("import ../../build/nimproto/protos") == initHashSet[string]()
    check importedComponents("import xcore/y, mycommon/z") == initHashSet[string]()      # a name that merely ends like a component

suite "D-81 the components import what they may and nothing else":
  for c in components:
    test "D-81 " & c & " imports " & (if allowed[c].len == 0: "nothing of ours" else: allowed[c].join(", ")):
      var found: HashSet[string]
      var offenders: seq[string]
      for f in moduleFiles(c):
        let used = importedComponents(readFile(f))
        for u in used:
          if u != c:
            found.incl u
            if u notin allowed[c]: offenders.add f.extractFilename & " -> " & u
      check offenders == newSeq[string]()
  test "D-82 the table of what each component is made of in .ci/pipeline.lua (DEPENDS) is this one":
    let script = readFile(currentSourcePath().parentDir.parentDir.parentDir / ".ci" / "pipeline.lua")
    let at = script.find("local DEPENDS = {")
    require at >= 0
    let table = script[at ..< script.find('\n', at)]
    for c in components:
      let want = allowed[c]
      let key = c & " = {"
      let k = table.find(key)
      require k >= 0
      let inside = table[k + key.len ..< table.find('}', k)]
      let got = inside.split(',').mapIt(it.strip.strip(chars = {'"'})).filterIt(it.len > 0)
      check got.sorted == want.sorted

  test "D-81 every directory of src/ is a component of this list (a new one is added here and to DEPENDS in .ci/pipeline.lua)":
    var dirs: seq[string]
    for kind, p in walkDir(currentSourcePath().parentDir.parentDir.parentDir / "src"):
      if kind == pcDir: dirs.add p.extractFilename
    check dirs.sorted == @components.sorted
