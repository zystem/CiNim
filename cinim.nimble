# Package

version       = "0.0.1"
author        = "CiNim"
description   = "Self-hosted Kubernetes-only CI/CD platform in Nim (spec v1.7)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"
requires "checksums >= 0.2.1"
requires "protobuf_serialization >= 0.6.2"

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

task testint, "Run integration tests (rqlite ones need CINIM_RQLITE_URL and CINIM_KUBECTL)":
  exec "tools/m0/gen_certs.sh"
  exec "nim c -r --hints:off --warnings:off -d:nngPrefix=$NNG_PREFIX --outdir:build/tests tests/integration/tnng.nim"
  # cluster tests (current kubeconfig context): need K8S_PREFIX from tools/k8s/build_client.sh and build/cicd-shim (musl, see docs/adr/0011)
  for t in ["tk8s", "tk8s2", "tk8s3", "tk8s4"]:
    exec "nim c -r --hints:off --warnings:off -d:k8sPrefix=$K8S_PREFIX --outdir:build/tests tests/integration/" & t & ".nim"
  exec "nim c -r --hints:off --warnings:off --outdir:build/tests tests/integration/trqlite.nim"

task testsan, "Run unit tests under AddressSanitizer/LeakSanitizer (E-004)":
  for f in listFiles("tests/unit"):
    if f.endsWith(".nim") and f.extractFilename.startsWith("t"):
      exec "nim c -r --hints:off --outdir:build/tests-san -d:sanitize " &
           "--passC:-fsanitize=address --passL:-fsanitize=address " &
           "--passC:-fno-omit-frame-pointer " & f
