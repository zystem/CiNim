switch("mm", "orc")
switch("threads", "on")
switch("path", "$projectDir/../../src")
when defined(release):
  switch("opt", "size")

# nim-grpc (github.com/zystem/nim-grpc, the shim's transport on the branch shim-grpc): a checkout named by NIM_GRPC, and the prefix of a static nghttp2 (include/ and lib/libnghttp2.a)
if existsEnv("NIM_GRPC"): switch("path", getEnv("NIM_GRPC") & "/src")
if existsEnv("NIM_BEARSSL"): switch("path", getEnv("NIM_BEARSSL"))
if existsEnv("NGHTTP2_PREFIX"): switch("define", "nghttp2Prefix=" & getEnv("NGHTTP2_PREFIX"))
