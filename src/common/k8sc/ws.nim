# Hand-written bindings (not generated) for the C client's WebSocket exec: kubernetes/websocket/{wsclient,kube_exec}.h.
# `kube_exec` runs a command in a Pod over the API server's exec endpoint and streams the output to a callback; the command is
# split on spaces (no quoting), which is all the shim's spool tool needs.
import apiclient, list
const
  wsHeader = "kubernetes/websocket/wsclient.h"
  execHeader = "kubernetes/websocket/kube_exec.h"

type
  wsclient_t* {.importc: "wsclient_t", header: wsHeader, bycopy.} = object
    data_callback_func* {.importc: "data_callback_func".}: proc (data: ptr pointer; len: ptr clong) {.cdecl.}

proc wsclient_create*(address: cstring; ssl: ptr sslConfig_t; tokens: ptr list_t; logMask: cint): ptr wsclient_t {.
  cdecl, importc: "wsclient_create", header: wsHeader.}
proc wsclient_free*(c: ptr wsclient_t) {.cdecl, importc: "wsclient_free", header: wsHeader.}
proc wsclient_run*(c: ptr wsclient_t; mode: cint): cint {.cdecl, importc: "wsclient_run", header: wsHeader.}
proc kube_exec*(c: ptr wsclient_t; ns, pod, container: cstring; stdin, stdout, tty: cint; command: cstring): cint {.
  cdecl, importc: "kube_exec", header: execHeader.}

proc setCallback*(c: ptr wsclient_t; f: proc (data: ptr pointer; len: ptr clong) {.cdecl.}) =
  c.data_callback_func = f
