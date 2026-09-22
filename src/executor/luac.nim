## Minimal FFI to the vendored Lua 5.4. io, os, debug, package and the stock
## lstate/linit are deliberately not compiled in (PIP-005 a).

import std/os

const
  luaDir = currentSourcePath().parentDir / ".." / ".." / "third_party" / "lua"
  glueDir = currentSourcePath().parentDir

{.passC: "-I" & luaDir.}
{.compile: glueDir / "lua_glue.c".}
{.compile: luaDir / "lapi.c".}
{.compile: luaDir / "lauxlib.c".}
{.compile: luaDir / "lbaselib.c".}
{.compile: luaDir / "lcode.c".}
{.compile: luaDir / "lcorolib.c".}
{.compile: luaDir / "lctype.c".}
{.compile: luaDir / "ldebug.c".}
{.compile: luaDir / "ldo.c".}
{.compile: luaDir / "ldump.c".}
{.compile: luaDir / "lfunc.c".}
{.compile: luaDir / "lgc.c".}
{.compile: luaDir / "llex.c".}
{.compile: luaDir / "lmathlib.c".}
{.compile: luaDir / "lmem.c".}
{.compile: luaDir / "lobject.c".}
{.compile: luaDir / "lopcodes.c".}
{.compile: luaDir / "lparser.c".}
{.compile: luaDir / "lstring.c".}
{.compile: luaDir / "lstrlib.c".}
{.compile: luaDir / "ltable.c".}
{.compile: luaDir / "ltablib.c".}
{.compile: luaDir / "ltm.c".}
{.compile: luaDir / "lundump.c".}
{.compile: luaDir / "lutf8lib.c".}
{.compile: luaDir / "lvm.c".}
{.compile: luaDir / "lzio.c".}

type
  LuaState* = distinct pointer
  LuaAlloc* = proc (ud, p: pointer; osize, nsize: csize_t): pointer {.cdecl.}
  LuaCFunction* = proc (L: LuaState): cint {.cdecl.}
  LuaHook* = proc (L: LuaState; ar: pointer) {.cdecl.}

const
  LUA_OK* = 0.cint
  LUA_YIELD* = 1.cint
  LUA_ERRMEM* = 4.cint
  LUA_REGISTRYINDEX* = -1001000.cint
  LUA_TBOOLEAN* = 1.cint
  LUA_TNUMBER* = 3.cint
  LUA_TSTRING* = 4.cint
  LUA_MASKCOUNT* = 8.cint

{.push importc, cdecl.}
proc lua_newstate*(f: LuaAlloc; ud: pointer): LuaState
proc lua_close*(L: LuaState)
proc lua_getallocf*(L: LuaState; ud: ptr pointer): LuaAlloc
proc lua_gettop*(L: LuaState): cint
proc lua_settop*(L: LuaState; idx: cint)
proc lua_type*(L: LuaState; idx: cint): cint
proc lua_tolstring*(L: LuaState; idx: cint; len: ptr csize_t): cstring
proc lua_pushstring*(L: LuaState; s: cstring): cstring
proc lua_error*(L: LuaState): cint
proc lua_sethook*(L: LuaState; f: LuaHook; mask, count: cint)
proc lua_rawgeti*(L: LuaState; idx: cint; n: int64): cint
proc lua_setupvalue*(L: LuaState; funcindex, n: cint): cstring
proc lua_pcallk*(L: LuaState; nargs, nresults, msgh: cint; ctx: int; k: pointer): cint
proc lua_newthread*(L: LuaState): LuaState
proc lua_resume*(L, fromL: LuaState; narg: cint; nres: ptr cint): cint
proc lua_pushlstring*(L: LuaState; s: cstring; len: csize_t): cstring
proc luaL_unref*(L: LuaState; t, r: cint)
proc luaL_ref*(L: LuaState; t: cint): cint
proc luaL_requiref*(L: LuaState; modname: cstring; openf: LuaCFunction; glb: cint)
proc luaL_loadbufferx*(L: LuaState; buff: cstring; sz: csize_t; name, mode: cstring): cint
proc luaopen_base*(L: LuaState): cint
proc luaopen_table*(L: LuaState): cint
proc luaopen_string*(L: LuaState): cint
proc luaopen_utf8*(L: LuaState): cint
proc luaopen_math*(L: LuaState): cint
proc luaopen_coroutine*(L: LuaState): cint
{.pop.}
