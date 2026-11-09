# Package

version       = "0.0.1"
author        = "CiNim"
description   = "Self-hosted Kubernetes-only CI/CD platform in Nim (see docs/specification.md)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"
requires "checksums >= 0.2.1"
requires "protobuf_serialization >= 0.6.2"
requires "crunchy >= 0.1.11"  # crc32c (DAT-001/logs.proto's LogChunk.crc32c) - no stdlib/checksums CRC32
requires "db_connector >= 0.1.0"  # sqlite state of the job-controller (adoption after a restart, D-33)
requires "zippy >= 0.10.0"  # compression of log blocks (src/shim/logspool.nim)
requires "nimja >= 0.10.0"  # server-side HTML templates of the UI (src/ui/render.nim)
# HTTP layer (D-25). 9.0.1 has our two fixes (the ~200 ms delay of a chunked response, olliNiinivaara/GuildenStern#35, and the delivered-byte
# count under backpressure, #36), which were a local patch on 9.0.0.
requires "guildenstern >= 9.0.2"
# gRPC (nghttp2 + BearSSL) for every channel of the platform: shim, controllers, conductors (docs/shim-grpc.md). It links a static nghttp2 1.61 or later from /opt/nghttp2 (Dockerfile.deps; `-d:nghttp2Prefix=<dir>` for another place).
requires "nimgrpc >= 0.3.0"

import std/os

# Tasks

task test, "Run unit tests":
  for f in listFiles("tests/unit"):
    if f.endsWith(".nim") and f.extractFilename.startsWith("t"):
      exec "nim c -r --hints:off --outdir:build/tests " & f

task testcontract, "Run protocol contract tests (need buf and the Python protoc venv for regenerating vectors)":
  exec "tools/proto/nim_flatten.sh build/nimproto"
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/contract/tproto_v0.nim"
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/contract/tproto_compat.nim"

task testint, "Run integration tests (need a cluster: CINIM_RQLITE_URL, K8S_PREFIX, kubeconfig; see README)":
  # cluster tests (current kubeconfig context): the Kubernetes exec primitive and the job-controller's spool fallback against a
  # real Pod (need K8S_PREFIX from tools/k8s/build_client.sh and build/cicd-shim-logging-static, see tools/shim/build_static.sh)
  for t in ["texec", "tdrain"]:
    exec "nim c -r --hints:off --warnings:off -d:k8sPrefix=$K8S_PREFIX --outdir:build/tests tests/integration/" & t & ".nim"
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/integration/trqlite.nim"
  exec "nim c -r --hints:off --warnings:off -p:src --outdir:build/tests tests/integration/torgruns.nim"     # needs CINIM_RQLITE_URL: a scratch rqlite
  # The end-to-end suite builds and runs core, job-controller and executor-service itself (see the header of
  # tests/integration/tm1skeleton.nim); only the job-controller links the Kubernetes client, so K8S_PREFIX is read from
  # the environment there. The channels (gRPC with mutual TLS; the tests make their own keys, tools/grpc/gen_tls.sh) need a static
  # nghttp2 in /opt/nghttp2 (or -d:nghttp2Prefix); the HTTP layer (GuildenStern, D-25) needs no build-time prefix.
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/integration/tm1skeleton.nim"

task testsan, "Run unit tests under AddressSanitizer/LeakSanitizer (E-004)":
  exec "sh tools/test/check-mmap-rnd.sh"        # fails with the cure when ASan binaries would crash at start (vm.mmap_rnd_bits above 28)
  for f in listFiles("tests/unit"):
    if f.endsWith(".nim") and f.extractFilename.startsWith("t"):
      exec "nim c -r --hints:off --outdir:build/tests-san -d:sanitize " &
           "--passC:-fsanitize=address --passL:-fsanitize=address " &
           "--passC:-fno-omit-frame-pointer " & f
