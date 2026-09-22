#!/bin/bash
# Compares two Kubernetes API access layers on the same workload (7 list calls with pagination, yyjson parsing, N cycles):
#   thin   = the k8s-image-availability-exporter layer (std/httpclient, SslContext, yaml kubeconfig), extracted verbatim
#   cclient = the official C client (generic API) through our generated bindings
# Usage: EXPORTER_DIR=~/github/k8s-image-availability-exporter K8S_PREFIX=<prefix> tools/k8s/clientbench.sh
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; EXP="${EXPORTER_DIR:-$HOME/github/k8s-image-availability-exporter}"; SRC="$EXP/src/k8s_image_availability_exporter.nim"
OUT="$HERE/build/k8sbench"; mkdir -p "$OUT"
{ echo 'import std/[base64, envvars, httpclient, net, options, os, re, sets, strutils, tables, times, uri]'
  echo 'import yyjson'; echo 'import yaml/[dom, loading]'; echo 'const Version = "bench"'
  echo 'type KubeClient* = object'; awk '/^  KubeClient\* = object/{f=1;next} f&&/^$/{exit} f' "$SRC"
  # from the TLS-context cache (or newExporterHttpClient in older versions) to the end of apiListBodies, unchanged
  awk '/^var sslContextCache|^proc newExporterHttpClient/{f=1} /^proc optStr/{f=0} f' "$SRC"
  cat "$HERE/tools/k8s/clientbench_main.nim"
} > "$OUT/bench.nim"
FLAGS="-d:release -d:ssl --threads:on --mm:orc --hints:off --warnings:off -p:$HERE/src"
nim c $FLAGS -o:"$OUT/bench_thin" "$OUT/bench.nim"
nim c $FLAGS -d:thinfixed -o:"$OUT/bench_thinfixed" "$OUT/bench.nim"
nim c $FLAGS -d:cclient -d:k8sPrefix="${K8S_PREFIX:?}" -o:"$OUT/bench_cclient" "$OUT/bench.nim"
nim c $FLAGS -d:cclient -d:cshare -d:k8sPrefix="$K8S_PREFIX" -o:"$OUT/bench_cshare" "$OUT/bench.nim"
ls -la "$OUT"/bench_thin "$OUT"/bench_thinfixed "$OUT"/bench_cclient "$OUT"/bench_cshare | awk '{print $5/1024 " KiB", $9}'
