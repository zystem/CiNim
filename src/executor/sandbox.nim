## Lua 5.4 sandbox for the pipeline executor (PIP-005, PIP-006).
##
## One Sandbox = one Lua state with a memory-limited allocator and an
## instruction budget. Limit hits are sticky: even if the script catches the
## error with pcall, `run` reports the limit code.

import luac

type
  Limiter = object
    used, memLimit: int
    instrCount, instrLimit, step: int
    memExceeded, instrExceeded: bool

  Sandbox* = object
    L*: LuaState
    lim: ptr Limiter
    envRef*, mainRef*: cint  ## registry refs: script _ENV, main-coroutine wrapper

  RunResult* = object
    code*: string     ## ok | script_error | memory_limit | instruction_limit
    message*: string  ## error text when code != ok
    value*: string    ## string/number/boolean returned by the script

proc cRealloc(p: pointer; n: csize_t): pointer {.importc: "realloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const hookStep = 1000

proc luaAlloc(ud, p: pointer; osize, nsize: csize_t): pointer {.cdecl.} =
  let lim = cast[ptr Limiter](ud)
  let old = if p == nil: 0 else: int(osize)  # osize is a type tag when p == nil
  if nsize == 0:
    if p != nil:
      cFree(p)
      lim.used -= old
    return nil
  let grow = int(nsize) - old
  if grow > 0 and lim.used + grow > lim.memLimit:
    lim.memExceeded = true
    return nil
  let q = cRealloc(p, nsize)
  if q == nil: return nil
  lim.used += grow
  q

# lua_error longjmps out of this frame: no Nim heap objects, and no Nim
# stack-trace frame either (it would never be popped).
proc countHook(L: LuaState; ar: pointer) {.cdecl, stackTrace: off, lineTrace: off.} =
  var ud: pointer
  discard lua_getallocf(L, addr ud)
  let lim = cast[ptr Limiter](ud)
  lim.instrCount += lim.step
  if lim.instrCount > lim.instrLimit:
    if not lim.instrExceeded:
      lim.instrExceeded = true
      lim.step = 1
    # Fire on every following instruction so pcall cannot keep a loop alive.
    lua_sethook(L, countHook, LUA_MASKCOUNT, 1)
    discard lua_pushstring(L, "instruction budget exceeded")
    discard lua_error(L)

proc `=destroy`(sb: var Sandbox) =
  if sb.L.pointer != nil:
    lua_close(sb.L)
    sb.L = LuaState(nil)
  if sb.lim != nil:
    dealloc(sb.lim)
    sb.lim = nil

proc `=copy`(dst: var Sandbox; src: Sandbox) {.error.}

proc memUsed*(sb: Sandbox): int = sb.lim.used
proc memLimit*(sb: Sandbox): int = sb.lim.memLimit

proc fetchString*(L: LuaState; idx: cint): string =
  var n: csize_t
  let s = lua_tolstring(L, idx, addr n)
  if s == nil: return ""
  result = newString(int(n))
  if n > 0: copyMem(addr result[0], s, int(n))

const bootstrap = staticRead("bootstrap.lua")

proc newSandbox*(memLimit = 64 * 1024 * 1024; instrLimit = 50_000_000): Sandbox =
  ## Defaults follow PIP-006: 64 MiB, 50M instructions between host calls.
  result.lim = create(Limiter)
  result.lim[] = Limiter(memLimit: memLimit, instrLimit: instrLimit, step: hookStep)
  result.L = lua_newstate(luaAlloc, result.lim)
  doAssert result.L.pointer != nil, "lua_newstate failed"
  let L = result.L
  luaL_requiref(L, "_G", luaopen_base, 1)
  luaL_requiref(L, "table", luaopen_table, 1)
  luaL_requiref(L, "string", luaopen_string, 1)
  luaL_requiref(L, "utf8", luaopen_utf8, 1)
  luaL_requiref(L, "math", luaopen_math, 1)
  luaL_requiref(L, "coroutine", luaopen_coroutine, 1)
  lua_settop(L, 0)
  doAssert luaL_loadbufferx(L, bootstrap.cstring, csize_t(bootstrap.len),
                            "=bootstrap", "t") == LUA_OK
  doAssert lua_pcallk(L, 0, 2, 0, 0, nil) == LUA_OK, fetchString(L, -1)
  result.mainRef = luaL_ref(L, LUA_REGISTRYINDEX)
  result.envRef = luaL_ref(L, LUA_REGISTRYINDEX)  # read-only script environment
  lua_settop(L, 0)
  lua_sethook(L, countHook, LUA_MASKCOUNT, hookStep.cint)

proc resetBudget*(sb: var Sandbox) =
  ## The instruction budget applies between host calls (PIP-006).
  sb.lim.instrCount = 0

proc limitCode*(sb: Sandbox): string =
  ## Sticky limit hit of this sandbox, or "".
  if sb.lim.memExceeded: "memory_limit"
  elif sb.lim.instrExceeded: "instruction_limit"
  else: ""

proc run*(sb: var Sandbox; code: string; name = "script"): RunResult =
  let L = sb.L
  let top = lua_gettop(L)
  sb.lim.instrCount = 0
  var st = luaL_loadbufferx(L, code.cstring, csize_t(code.len), ("=" & name).cstring, "t")
  if st == LUA_OK:
    discard lua_rawgeti(L, LUA_REGISTRYINDEX, sb.envRef)
    discard lua_setupvalue(L, -2, 1)  # _ENV of the main chunk
    st = lua_pcallk(L, 0, 1, 0, 0, nil)
  if st == LUA_OK:
    case lua_type(L, -1)
    of LUA_TSTRING, LUA_TNUMBER, LUA_TBOOLEAN:
      result.value = fetchString(L, -1)
    else: discard
  else:
    result.message = fetchString(L, -1)
    if result.message.len == 0: result.message = "error object is not a string"
  lua_settop(L, top)
  if sb.lim.memExceeded: result.code = "memory_limit"
  elif sb.lim.instrExceeded: result.code = "instruction_limit"
  elif st != LUA_OK: result.code = "script_error"
  else: result.code = "ok"
