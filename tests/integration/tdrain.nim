## The exec fallback end to end against a real cluster, with the controller's own pieces (k8s backend + logic.drainSpool): a step Pod
## whose shim cannot reach core (nothing listens) spools its output; drainSpool must get every block out through exec.
import std/[os, osproc, strutils, unittest, json, times]
import common/spoolwire
import jobcontroller/[backend, k8s, logic]

let prefix = getEnv("K8S_PREFIX")
let ns = getEnv("CINIM_EXEC_NS", "cinim-exec-test")
let kubeconfig = getEnv("CINIM_KUBECONFIG", "")
let shimBin = getEnv("CINIM_STATIC_SHIM", "build/cicd-shim-logging-static")
let certs = getEnv("CINIM_CERTS", getCurrentDir() / "tests" / "certs")

suite "drainSpool against a real Pod":
  if prefix.len == 0:
    test "skipped: K8S_PREFIX not set":
      skip()
  else:
    test "blocks come out whole and in order through the controller's backend":
      let kc = " --kubeconfig " & kubeconfig
      discard execCmd("kubectl" & kc & " create namespace " & ns & " 2>/dev/null")
      let k = connectK8s(ns, kubeconfig)
      k.ensureShimAssets(shimBin, certs, withCerts = true)
      let be = backendOf(k)
      var cfg = defaultConfig()
      cfg.collectorAddr = "tcp://127.0.0.1:1"          # nobody listens: everything stays in the spool
      cfg.stepReportAddr = "tcp://127.0.0.1:1"
      let rq = buildRequest(cfg, StartRequest(runId: "s1_drain", seq: 0, attempt: 1, image: "busybox:1.36",
        command: @["sh", "-c", "i=0; while [ $i -lt 3000 ]; do echo line-$i-padding-padding-padding-padding-padding; i=$((i+1)); done; sleep 600"]))
      discard execCmd("kubectl" & kc & " -n " & ns & " delete pod " & rq.name & " --ignore-not-found --wait=true >/dev/null 2>&1")
      check be.createPod(rq)
      check execCmd("kubectl" & kc & " -n " & ns & " wait --for=condition=Ready pod/" & rq.name & " --timeout=90s") == 0
      sleep 12000
      let t0 = epochTime()
      let frames = drainSpool(be, rq.name)
      echo "drained ", frames.len, " blocks in ", formatFloat(epochTime() - t0, ffDecimal, 1), " s"
      check frames.len >= 1
      var lines = 0'u32
      for i, f in frames:
        check f.seq == uint64(i + 1)
        lines += f.lines
      check lines >= 3000
      check be.ackSpool(rq.name, frames[^1].seq)
      check drainSpool(be, rq.name).len == 0                 # acknowledged blocks are gone
      discard execCmd("kubectl" & kc & " -n " & ns & " delete pod " & rq.name & " --wait=false >/dev/null 2>&1")
