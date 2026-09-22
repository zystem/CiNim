/* Lua 5.4 lstate.c with a fixed string-hash seed (PIP-005 d, [M0-CHECK]):
   the stock seed mixes in addresses and time, which breaks replay determinism. */
#define luai_makeseed(L) 0x5eed5eedu
#include "lstate.c"
