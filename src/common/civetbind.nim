## civetweb (C, MIT) bindings: generated module plus linker flags. Build with -d:civetPrefix=<dir with include/ and lib/>.
import civetc/civetweb
export civetweb

const civetPrefix* {.strdefine.} = ""
when civetPrefix.len > 0:
  {.passC: "-I" & civetPrefix & "/include".}
  {.passL: "-L" & civetPrefix & "/lib -lcivetweb -lssl -lcrypto -lpthread -ldl -lm".}
