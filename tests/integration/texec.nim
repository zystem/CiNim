## Run a command in a Pod through the C client's WebSocket exec (kube_exec) and read its stdout (D-29, the fallback
## for a shim that cannot reach core). Needs K8S_PREFIX and a cluster; creates one busybox Pod in CINIM_EXEC_NS.
import std/[os, osproc, strutils, unittest]
import checksums/sha2
import common/spoolwire
import common/k8sbind

let prefix = getEnv("K8S_PREFIX")
let ns = getEnv("CINIM_EXEC_NS", "cinim-exec-test")
let kubeconfig = getEnv("CINIM_KUBECONFIG", "")

var captured {.threadvar.}: string
proc onData(data: ptr pointer; len: ptr clong) {.cdecl.} =
  if data != nil and data[] != nil and len != nil and len[] > 0:
    let n = int(len[])
    var s = newString(n)
    copyMem(addr s[0], data[], n)
    captured.add s

suite "kube_exec":
  if prefix.len == 0:
    test "skipped: K8S_PREFIX not set":
      skip()
  else:
    test "exec echo in a running Pod and capture the output":
      discard execCmd("kubectl --kubeconfig " & kubeconfig & " create namespace " & ns & " 2>/dev/null")
      discard execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " run exectest --image=busybox:1.36 --restart=Never -- sleep 3600 2>/dev/null")
      check execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " wait --for=condition=Ready pod/exectest --timeout=90s") == 0
      var base: cstring
      var ssl: ptr sslConfig_t
      var keys: ptr list_t
      check load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, (if kubeconfig.len > 0: kubeconfig.cstring else: nil.cstring)) == 0
      let api = apiClient_create_with_base_path(base, ssl, keys)
      let wsc = wsclient_create(api.basePath, api.sslConfig, api.apiKeys_BearerToken, 0)
      check wsc != nil
      setCallback(wsc, onData)
      captured = ""
      let rc = kube_exec(wsc, ns.cstring, "exectest".cstring, "exectest".cstring, 0, 1, 0, "echo hello-from-exec")
      check rc == 0
      discard wsclient_run(wsc, 0)
      echo "captured: ", captured.repr
      check "hello-from-exec" in captured
      wsclient_free(wsc)

    test "a binary megabyte comes through intact (no NUL, high-bit or newline damage)":
      proc runIn(cmd: string): string =
        var base: cstring
        var ssl: ptr sslConfig_t
        var keys: ptr list_t
        doAssert load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, (if kubeconfig.len > 0: kubeconfig.cstring else: nil.cstring)) == 0
        let api = apiClient_create_with_base_path(base, ssl, keys)
        let wsc = wsclient_create(api.basePath, api.sslConfig, api.apiKeys_BearerToken, 0)
        setCallback(wsc, onData)
        captured = ""
        doAssert kube_exec(wsc, ns.cstring, "exectest".cstring, "exectest".cstring, 0, 1, 0, cmd.cstring) == 0
        discard wsclient_run(wsc, 0)
        wsclient_free(wsc)
        captured
      let bin = runIn("cat /bin/busybox")
      let remoteSum = runIn("sha256sum /bin/busybox").splitWhitespace[0]
      var localSum = ""
      for c in secureHash(Sha_256, bin): localSum.add toHex(ord(c), 2).toLowerAscii
      echo "bytes: ", bin.len, " sha ", localSum
      check bin.len > 500_000
      check localSum == remoteSum

    test "the shim's spool tool through exec: 5 MB of blocks arrive whole, are acknowledged and removed":
      let shim = getEnv("CINIM_STATIC_SHIM", "build/cicd-shim-logging-static")
      check execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " delete pod spoolpod --ignore-not-found --wait=true >/dev/null 2>&1") == 0
      discard execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " delete configmap cicd-shim --ignore-not-found >/dev/null 2>&1")
      check execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " create configmap cicd-shim --from-file=cicd-shim=" & shim) == 0
      writeFile("/tmp/spoolpod.yaml", """
apiVersion: v1
kind: Pod
metadata: {name: spoolpod}
spec:
  restartPolicy: Never
  containers:
  - name: spoolpod
    image: busybox:1.36
    command: ["/cicd/shim/cicd-shim", "--run-dir", "/tmp/run", "--collector-addr", "tcp://127.0.0.1:1", "--core-addr", "tcp://127.0.0.1:1",
              "--certs-dir", "/nonexistent", "--run-id", "s1_x", "--step-seq", "0", "--step-attempt", "1", "--log-spool-dir", "/tmp/spool",
              "--log-spool-bytes", "30000000", "--log-hold-timeout", "900", "--", "sh", "-c", "head -c 4000000 /dev/urandom | base64; sleep 900"]
    volumeMounts: [{name: shim, mountPath: /cicd/shim}]
  volumes: [{name: shim, configMap: {name: cicd-shim, defaultMode: 493}}]
""")
      check execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " apply -f /tmp/spoolpod.yaml") == 0
      check execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " wait --for=condition=Ready pod/spoolpod --timeout=90s") == 0
      sleep 15000                                          # the build has written its output into the spool by now
      proc runIn(cmd: string): string =
        var base: cstring
        var ssl: ptr sslConfig_t
        var keys: ptr list_t
        doAssert load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, (if kubeconfig.len > 0: kubeconfig.cstring else: nil.cstring)) == 0
        let api = apiClient_create_with_base_path(base, ssl, keys)
        let wsc = wsclient_create(api.basePath, api.sslConfig, api.apiKeys_BearerToken, 0)
        setCallback(wsc, onData)
        captured = ""
        doAssert kube_exec(wsc, ns.cstring, "spoolpod".cstring, "spoolpod".cstring, 0, 1, 0, cmd.cstring) == 0
        discard wsclient_run(wsc, 0)
        wsclient_free(wsc)
        captured
      # The C client's WebSocket exec is lossy for bulk data (measured: damage after ~1 MB in one call, even paced), so the
      # tool is used in small calls: each returns a valid prefix of whole, checksummed blocks; those are taken and acknowledged,
      # the damaged remainder is simply read again in the next call.
      var next = 1'u64
      var totalLines = 0'u64
      var calls = 0
      var damagedCalls = 0
      while calls < 200:
        inc calls
        let r = parseFrames(runIn("/cicd/shim/cicd-shim --read-spool /tmp/spool --after-seq " & $(next - 1) & " --max-bytes 400000"))
        if r.damaged: inc damagedCalls
        if r.frames.len == 0:
          if r.damaged: continue                                           # nothing usable this time: ask again
          break                                                            # empty and not damaged: the spool is drained
        for f in r.frames:
          check f.seq == next                                              # whole blocks, in order, none missing
          inc next
          totalLines += f.lines
        discard runIn("/cicd/shim/cicd-shim --ack-spool /tmp/spool --upto " & $(next - 1))
      echo "calls: ", calls, " damaged calls: ", damagedCalls, " blocks: ", next - 1, " lines: ", totalLines
      check next > 10
      check totalLines >= 70000                                            # 4 MB of base64 at 76 characters per line
      let leftover = parseFrames(runIn("/cicd/shim/cicd-shim --read-spool /tmp/spool"))
      check leftover.frames.len == 0 and not leftover.damaged               # everything was read and acknowledged
      discard execCmd("kubectl --kubeconfig " & kubeconfig & " -n " & ns & " delete pod spoolpod --wait=false >/dev/null 2>&1")
