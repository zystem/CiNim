switch("mm", "orc")
switch("threads", "on")
switch("path", "$projectDir/../../src")
# GuildenStern (the HTTP server of every service, common/httpsrv.nim) hands its events to the workers through a queue of QueueSize places, 200 unless told, and fills it again from the
# start: a request that is still being handled when the queue comes round to its place loses its connection (the next request on it is never read; found 2026-11-16, 9.0.2 and its master,
# tests/integration/thttp.nim). 20 000 places make a lap a hundred times longer: a request must outlast 20 000 others. It is a mitigation, not the cure, which is in the library.
# The memory is 8 bytes a place for each of the 30 servers the library allows: 4.8 MB of zero pages, touched only as far as the queue is used.
switch("define", "QueueSize=20000")
when defined(release):
  switch("opt", "size")

# nimgrpc (nimble package; the shim's transport on the branch shim-grpc) links a static nghttp2 from /opt/nghttp2 (include/ and lib/libnghttp2.a); NGHTTP2_PREFIX names another place
if existsEnv("NGHTTP2_PREFIX"): switch("define", "nghttp2Prefix=" & getEnv("NGHTTP2_PREFIX"))
