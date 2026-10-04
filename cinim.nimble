# Package

version       = "0.0.1"
author        = "CiNim"
description   = "Self-hosted Kubernetes-only CI/CD platform in Nim (spec v1.13)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"
requires "checksums >= 0.2.1"
requires "protobuf_serialization >= 0.6.2"
requires "uniq >= 0.2.1"  # UUIDv7 identifiers (common.proto: "shard>_<uuidv7>", SHD-004)
requires "crunchy >= 0.1.11"  # crc32c (DAT-001/logs.proto's LogChunk.crc32c) - no stdlib/checksums CRC32
requires "db_connector >= 0.1.0"  # sqlite state of the job-controller (adoption after a restart, D-33)
# HTTP layer (D-25): upstream 9.0.0 plus two small fixes, docs/patches/guildenstern-9.0.0.patch (apply to the installed package;
# the fixes are sent upstream as olliNiinivaara/GuildenStern#35 and #36).
requires "guildenstern >= 9.0.0"
# ZeroMQ+CURVE transport (D-24): our fork, not upstream, while
# nim-lang/nim-zmq#57 (high-level CURVE: connect/listen configure callback) is open. Branch `cinim` of the fork is
# upstream master (which already has #58, the setsockopt value-width fix, and #59, the `=destroy` leak fix) plus #57;
# switch back to upstream once #57 is released.
requires "https://github.com/zystem/nim-zmq#cinim"

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
  exec "tools/zmq/gen_curve_keys.sh"
  # cluster tests (current kubeconfig context): the Kubernetes exec primitive and the job-controller's spool fallback against a
  # real Pod (need K8S_PREFIX from tools/k8s/build_client.sh and build/cicd-shim-logging-static, see tools/shim/build_static.sh)
  for t in ["texec", "tdrain"]:
    exec "nim c -r --hints:off --warnings:off -d:k8sPrefix=$K8S_PREFIX --outdir:build/tests tests/integration/" & t & ".nim"
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/integration/trqlite.nim"
  exec "nim c -r --hints:off --warnings:off -p:src --outdir:build/tests tests/integration/torgruns.nim"     # needs CINIM_RQLITE_URL: a scratch rqlite
  # The end-to-end suite builds and runs core, job-controller and executor-service itself (see the header of
  # tests/integration/tm1skeleton.nim); only the job-controller links the Kubernetes client, so K8S_PREFIX is read from
  # the environment there. All ZeroMQ+CURVE channels (D-24) and the HTTP layer (GuildenStern, D-25) need no
  # build-time prefix: libzmq is loaded at run time.
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/integration/tm1skeleton.nim"

task testsan, "Run unit tests under AddressSanitizer/LeakSanitizer (E-004)":
  for f in listFiles("tests/unit"):
    if f.endsWith(".nim") and f.extractFilename.startsWith("t"):
      exec "nim c -r --hints:off --outdir:build/tests-san -d:sanitize " &
           "--passC:-fsanitize=address --passL:-fsanitize=address " &
           "--passC:-fno-omit-frame-pointer " & f
