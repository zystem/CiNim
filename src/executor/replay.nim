## Journaled execution of a pipeline script (PIP-003, PIP-004).
##
## The script runs as a coroutine; every host call yields (kind, payload).
## Calls with a journal record are answered from the journal (replay), the
## first call without one goes to the host and is appended.

import std/[options, strutils, tables, sets, json]
import luac, sandbox, journal

type
  HostCallProc* = proc (seq: int; kind, payload: string): Option[string] {.closure.}
    ## Performs a call. `none` is "pending": the call has no answer yet (a step that waits or runs, a lock that is not the run's turn). The branch that made it waits; the others
    ## go on, and when none can the run is suspended (docs/parallel.md section 5). A call that is pending stays so for the rest of this execution.

  HostSuspend* = object of CatchableError
    ## Raised by a host that must stop the execution at once and suspend the run, whatever the branches could still do (the lease was lost).

  HostRefusal* = object of CatchableError
    ## Raised by a host when the core refuses a call for good (an unknown secret, a profile the shard does not have): the run fails with `code` and the
    ## message, as a script error does. Without it the refusal looked like "suspended" and the run was asked again for ever.
    code*: string

  ExecStatus* = enum esDone, esSuspended, esFailed

  ExecResult* = object
    status*: ExecStatus
    code*: string     ## ok | suspended | script_error | script_nondeterminism |
                      ## journal_corrupt | journal_limit | memory_limit | instruction_limit
    message*: string
    value*: string

const hostKinds = ["now", "random", "sh", "sleep", "job_sh", "params", "lock", "unlock", "par_cancel", "par_peek"]

proc cancelPayload(text: string; placeKeys: Table[string, string]): string =
  ## The decision of `fail_fast` as the script's scheduler writes it (bootstrap.lua): the path of the `ci.parallel`, the branch that failed, the branches not started (tabs), and
  ## then the place of each step to cancel (`ctx<TAB>line<TAB>nth`), one to a line. The journal and the core get it as JSON with the places turned into the keys of the steps.
  let lines = text.split('\n')
  var d = %*{"by": (if lines.len > 0: lines[0] else: ""), "failed": (if lines.len > 1: lines[1] else: ""), "unstarted": [], "steps": []}
  if lines.len > 2:
    for u in lines[2].split('\t'):
      if u.len > 0: d["unstarted"].add %u
  for i in 3 ..< lines.len:
    let key = placeKeys.getOrDefault(lines[i], "")
    if key.len > 0: d["steps"].add %key
  $d

proc failed(code, msg: string): ExecResult =
  ExecResult(status: esFailed, code: code, message: msg)

proc execute*(sb: var Sandbox; j: var Journal; code: string; host: HostCallProc;
              onAppend: proc (e: Entry) = nil; maxEntries = 100_000; runId = "";
              params: seq[(string, string)] = @[];
              onSite: proc (seq: int; kind: string; line: int) = nil;
              onCall: proc (seq: int; kind, key: string) = nil;
              stepKey: proc (): string = nil;
              onPlace: proc (seq: int; kind: string; line: int; ctx: string; nth: int) = nil): ExecResult =
  ## `params` are the launch parameters given when the run was created, as text. `onSite` is told, for every host call that has one, the line of the script it was made on
  ## (a step: docs/parallel.md section 3.4); the table of step numbers is made from it. Every call has a **key**, the identity under which the journal keeps its answer: for a
  ## step `stepKey()` (the caller's `s<number>`; without one `s<n>`, the n-th step), for any other call `<kind>#<n>`, the n-th call of that kind. The journal is found by key, so
  ## a record may be missing or be anywhere (a retry of only the failed steps, branches that end in any order): a call without a record goes to the host. `onCall` is told
  ## the key before the host is.
  ## `ctx` and `nth` say where a call is made in the tree of branches (docs/parallel.md section 3.1): `ctx` is the path (`m` for `main`, `m.p1[unit]` for the branch `unit` of the first
  ## `ci.parallel` of `main`) and `nth` the number of this call there: the n-th call of its kind in that context, or for a step the n-th that was made on `line` there. Both are
  ## counted by the script in the branch, never by the order in which the host answered, so the key of a call is the same in every replay. `onPlace` is told them for every call
  ## (once, when the call is first made, right before the host is asked), `onSite` the line only.
  ## `runId` is passed to a real (`ci.pipeline`) script's `main(run)` as `run.run_id` (`lua/stdlib/cicd.d.lua`'s `Run` is a bigger table; only `run_id` exists so far). A script that
  ## returns a plain value directly, as the sandbox test fixtures do, ignores the extra argument.
  if not j.verify():
    return failed("journal_corrupt", "hash chain does not verify")
  let L = sb.L
  let co = lua_newthread(L)
  let anchor = luaL_ref(L, LUA_REGISTRYINDEX)  # keeps the thread alive; pops it
  defer: luaL_unref(L, LUA_REGISTRYINDEX, anchor)

  discard lua_rawgeti(co, LUA_REGISTRYINDEX, sb.mainRef)
  if luaL_loadbufferx(co, code.cstring, csize_t(code.len), "=script", "t") != LUA_OK:
    return failed("script_error", fetchString(co, -1))
  discard lua_rawgeti(co, LUA_REGISTRYINDEX, sb.envRef)
  discard lua_setupvalue(co, -2, 1)
  lua_createtable(co, 0, 1)
  discard lua_pushstring(co, runId.cstring)
  lua_setfield(co, -2, "run_id")
  # the launch parameters as text, for the bootstrap to check against the script's declarations (PIP-012); it removes this field before `main` runs
  lua_createtable(co, 0, cint(params.len))
  for (k, v) in params:
    discard lua_pushlstring(co, v.cstring, csize_t(v.len))
    lua_setfield(co, -2, k.cstring)
  lua_setfield(co, -2, "__given")

  var nargs = 2.cint
  var seq = 0
  var stepsMade = 0                              # the n-th step, the key of a step when the caller gives no numbers (`stepKey`)
  var firstPending = ""                          # what the run waits for, for the message of a suspension
  var placeKeys = initTable[string, string]()    # `ctx<TAB>line<TAB>nth` of a step -> its key, for the decision of fail_fast
  var index = initTable[string, int]()           # key -> place in j.entries, so that a long journal is not searched at every call
  for i, e in j.entries: index[e.key] = i
  # A run that was run again (docs/parallel.md section 11): the journal holds records of kind `retry`, each naming the keys it supersedes. The record of a step that failed stays in
  # the journal (it is chained and is never taken out), but it is no longer the answer: the step is found under `<key>~1`, and after a second retry under `<key>~2`.
  var superseded = initHashSet[string]()
  for e in j.entries:
    if e.kind == "retry":
      try:
        for k in parseJson(e.payload): superseded.incl k.getStr
      except CatchableError: discard
  proc effectiveKey(base: string): string =
    result = base
    var r = 0
    while result in superseded:
      inc r
      result = base & "~" & $r
  while true:
    sb.resetBudget()
    var nres: cint
    let rs = lua_resume(co, L, nargs, addr nres)
    let hit = sb.limitCode()
    if hit.len > 0: return failed(hit, "limit exceeded")
    if rs == LUA_YIELD:
      let base = lua_gettop(co) - nres + 1
      let kind = if nres >= 1: fetchString(co, base) else: ""
      if kind == "__suspend":                    # every branch waits for something (bootstrap.lua `park`)
        return ExecResult(status: esSuspended, code: "suspended", message: firstPending)
      if nres != 5: return failed("script_error", "malformed host call")
      var payload = fetchString(co, base + 1)
      let line = int(lua_tointegerx(co, base + 2, nil))
      let ctx = fetchString(co, base + 3)
      let nth = int(lua_tointegerx(co, base + 4, nil))
      lua_settop(co, 0)
      if kind notin hostKinds:
        return failed("script_error", "unknown host call '" & kind & "'")
      if kind == "par_peek":
        # not a call: has the decision of the ci.parallel at path `payload` been taken in an earlier execution? The answer is its journaled result, "" if not. Nothing is asked, nothing written.
        let at = index.getOrDefault(payload & "/par_cancel#0", -1)
        let known = if at >= 0: j.entries[at].result else: ""
        discard lua_pushlstring(co, known.cstring, csize_t(known.len))
        nargs = 1
        continue
      if onSite != nil: onSite(seq, kind, line)          # line 0: the host call has none (a step without one is numbered from the overflow)
      if onPlace != nil: onPlace(seq, kind, line, ctx, nth)
      var res: string
      let base0 = if kind == "job_sh": (if stepKey != nil: stepKey() else: "s" & $stepsMade) else: kind & "#" & $nth
      let key = effectiveKey(if kind != "job_sh" and ctx != "m": ctx & "/" & base0 else: base0)
      if kind == "job_sh":
        inc stepsMade
        placeKeys[ctx & "\t" & $line & "\t" & $nth] = key
      if kind == "par_cancel": payload = cancelPayload(payload, placeKeys)
      if onCall != nil: onCall(seq, kind, key)
      let at = index.getOrDefault(key, -1)
      var pending = false
      if at >= 0:
        let e = j.entries[at]
        if e.kind != kind or (kind != "par_cancel" and e.payload != payload):        # a decision is replayed as it was taken: what the script computes now may differ
          return failed("script_nondeterminism",
            "seq " & $seq & " (key " & key & "): journal has " & e.kind & "(" & e.payload &
            "), script called " & kind & "(" & payload & ")")
        res = e.result
      else:
        if j.entries.len >= maxEntries:
          return failed("journal_limit", "journal reached " & $maxEntries & " entries")
        var r: Option[string]
        try:
          r = host(seq, kind, payload)
        except HostRefusal as refused:
          return failed(if refused.code.len > 0: refused.code else: "script_error", refused.msg)
        except HostSuspend:
          return ExecResult(status: esSuspended, code: "suspended", message: "waiting on seq " & $seq & " " & kind)
        if r.isNone:
          pending = true
          if firstPending.len == 0: firstPending = "waiting on seq " & $seq & " " & kind
        else:
          res = r.get
          let e = j.append(key, kind, payload, res)
          index[key] = j.entries.len - 1
          if onAppend != nil: onAppend(e)
      if pending:
        lua_pushnil(co)                          # the branch that asked parks; nothing else of this call is kept
      else:
        inc seq
        discard lua_pushlstring(co, res.cstring, csize_t(res.len))
      nargs = 1
    elif rs == LUA_OK:
      result = ExecResult(status: esDone, code: "ok")
      if nres > 0 and lua_type(co, -1) in [LUA_TSTRING, LUA_TNUMBER, LUA_TBOOLEAN]:
        result.value = fetchString(co, -1)
      return
    else:
      let msg = fetchString(co, -1)
      # the errors of the host API that have a code of their own: the message begins with it (bootstrap.lua), possibly after the position `script:12:`
      for code in ["duplicate_id", "step_limit"]:
        if (code & ":") in msg: return failed(code, msg)
      return failed("script_error", msg)
