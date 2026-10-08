## Journaled execution of a pipeline script (PIP-003, PIP-004).
##
## The script runs as a coroutine; every host call yields (kind, payload).
## Calls with a journal record are answered from the journal (replay), the
## first call without one goes to the host and is appended.

import std/options
import luac, sandbox, journal

type
  HostCallProc* = proc (seq: int; kind, payload: string): Option[string] {.closure.}
    ## Performs a call. `none` suspends the run (approval, waiting for a step).

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

const hostKinds = ["now", "random", "sh", "sleep", "job_sh"]

proc failed(code, msg: string): ExecResult =
  ExecResult(status: esFailed, code: code, message: msg)

proc execute*(sb: var Sandbox; j: var Journal; code: string; host: HostCallProc;
              onAppend: proc (e: Entry) = nil; maxEntries = 100_000; runId = ""): ExecResult =
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

  var nargs = 2.cint
  var seq = 0
  while true:
    sb.resetBudget()
    var nres: cint
    let rs = lua_resume(co, L, nargs, addr nres)
    let hit = sb.limitCode()
    if hit.len > 0: return failed(hit, "limit exceeded")
    if rs == LUA_YIELD:
      if nres != 2: return failed("script_error", "malformed host call")
      let kind = fetchString(co, -2)
      let payload = fetchString(co, -1)
      lua_settop(co, 0)
      if kind notin hostKinds:
        return failed("script_error", "unknown host call '" & kind & "'")
      var res: string
      if seq < j.entries.len:
        let e = j.entries[seq]
        if e.kind != kind or e.payload != payload:
          return failed("script_nondeterminism",
            "seq " & $seq & ": journal has " & e.kind & "(" & e.payload &
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
        if r.isNone:
          return ExecResult(status: esSuspended, code: "suspended",
                            message: "waiting on seq " & $seq & " " & kind)
        res = r.get
        let e = j.append(kind, payload, res)
        if onAppend != nil: onAppend(e)
      inc seq
      discard lua_pushlstring(co, res.cstring, csize_t(res.len))
      nargs = 1
    elif rs == LUA_OK:
      result = ExecResult(status: esDone, code: "ok")
      if nres > 0 and lua_type(co, -1) in [LUA_TSTRING, LUA_TNUMBER, LUA_TBOOLEAN]:
        result.value = fetchString(co, -1)
      return
    else:
      return failed("script_error", fetchString(co, -1))
