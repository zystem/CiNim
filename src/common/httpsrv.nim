## The HTTP server of the services (GuildenStern, D-25), made the one way that works.
##
## GuildenStern reads the length of a body with `getContentLength`, which looks for "content-length: " in the **whole** receive buffer of the thread, not only in the part
## that the current request filled. The buffer is kept from request to request, so after a POST has been read by a thread, the text of its header stays behind the end of
## the next, shorter request (a GET, say), is found there, and the server answers that request by closing the connection ("could not parse content-length"). A few dozen
## POSTs are enough for a third of the following connections to be dropped, until the threads' buffers are overwritten by longer requests; a `kubectl port-forward` dies at the first
## drop. Asking for the header field by name (`headerfields`) makes the library read the headers with `parseHeaders`, which stays inside the request. Upstream 9.0.1 has the fault; the fix is offered as olliNiinivaara/GuildenStern#38 - when a release has it, `headerfields` here is no longer needed (keep the test).
##
## Every service that serves HTTP makes its server here.
import guildenstern/[dispatcher, httpserver]
export dispatcher, httpserver

proc newService*(onrequest: proc() {.gcsafe, nimcall, raises: [].}; streaming = false): HttpServer =
  ## `streaming`: the body is not read for the callback; it reads it itself, piece by piece, with `receiveStream` (the storage module does, storage/service.nim). The default reads the
  ## whole body into the receive buffer (`bufferlength`) first.
  newHttpServer(onrequest, headerfields = ["content-length"], contenttype = (if streaming: Streaming else: Compact))
