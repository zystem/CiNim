/* Lua 5.4 lstate.c with a fixed string-hash seed (PIP-005 d):
   the stock seed mixes in addresses and time, which breaks replay determinism. */
#define luai_makeseed(L) 0x5eed5eedu
#include "lstate.c"

/* The line of the script that called the Lua function that called this one (lua_getstack level 2): where a step is made, for the table of step numbers
   (docs/parallel.md section 3.4). Lua's debug interface gives lines but not columns. 0 if there is none. */
#include "lua.h"
int ci_line(lua_State *L) {
  lua_Debug ar;
  if (lua_getstack(L, 2, &ar) && lua_getinfo(L, "l", &ar) && ar.currentline > 0) lua_pushinteger(L, ar.currentline);
  else lua_pushinteger(L, 0);
  return 1;
}
