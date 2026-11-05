switch("mm", "orc")
switch("threads", "on")
switch("path", "$projectDir/../../src")
when defined(release):
  switch("opt", "size")

# nimgrpc (nimble package; the shim's transport on the branch shim-grpc) links a static nghttp2 from /opt/nghttp2 (include/ and lib/libnghttp2.a); NGHTTP2_PREFIX names another place
if existsEnv("NGHTTP2_PREFIX"): switch("define", "nghttp2Prefix=" & getEnv("NGHTTP2_PREFIX"))
