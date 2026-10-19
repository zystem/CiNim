## The HTTP server of the services (GuildenStern, D-25), made one way: here.
##
## GuildenStern 9.0.1 read the length of a body with `getContentLength`, which looked for "content-length: " in the **whole** receive buffer of the thread, not only in the part
## that the current request filled. The buffer is kept from request to request, so after a POST had been read by a thread, the text of its header stayed behind the end of the next,
## shorter request (a GET, say), was found there, and the server answered that request by closing the connection ("could not parse content-length"): a third of the connections after a
## few dozen POSTs, and a `kubectl port-forward` died at the first drop. The fix is ours, olliNiinivaara/GuildenStern#38 (merged 2026-10-19, release 9.0.2: `cinim.nimble` asks for it), and
## the workaround that stood here (asking for `content-length` by name in `headerfields`, which reads the headers another way) is gone. `tests/integration/thttp.nim` stays: it fails on 9.0.1.
## One thing the fix leaves: the default reading finds only the spellings `content-length: ` and `Content-Length: ` (not CONTENT-LENGTH, and not a header with no space after the colon);
## every client of ours sends one of the two.
##
## Every service that serves HTTP makes its server here.
import guildenstern/[dispatcher, httpserver]
export dispatcher, httpserver

proc newService*(onrequest: proc() {.gcsafe, nimcall, raises: [].}; streaming = false): HttpServer =
  ## `streaming`: the body is not read for the callback; it reads it itself, piece by piece, with `receiveStream` (the storage module does, storage/service.nim). The default reads the
  ## whole body into the receive buffer (`bufferlength`) first.
  newHttpServer(onrequest, contenttype = (if streaming: Streaming else: Compact))
