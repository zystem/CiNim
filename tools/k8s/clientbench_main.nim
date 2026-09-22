
# ---------------------------------------------------------------------------------------------- benchmark part
when defined(cclient):
  import common/k8sbind
  proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const resources = [("", "v1", "namespaces"), ("", "v1", "pods"), ("apps", "v1", "deployments"), ("apps", "v1", "statefulsets"),
                   ("apps", "v1", "daemonsets"), ("batch", "v1", "cronjobs"), ("", "v1", "serviceaccounts")]

proc rssKiB(): int = parseInt(readFile("/proc/self/statm").splitWhitespace()[1]) * 4

when defined(cclient):
  var api: ptr apiClient_t
  when defined(cshare):
    # libcurl share handle with a shared connection cache: connections survive the per-call easy handles of the C client
    proc curl_share_init(): pointer {.importc, header: "<curl/curl.h>".}
    proc curl_share_setopt(s: pointer; opt: cint; v: cint): cint {.importc, header: "<curl/curl.h>", discardable.}
    proc curl_easy_setopt(h: pointer; opt: cint; v: pointer): cint {.importc, header: "<curl/curl.h>", discardable.}
    var share: pointer
    proc preInvoke(h: ptr CURL) {.cdecl.} =
      discard curl_easy_setopt(cast[pointer](h), 10100.cint, share)      # CURLOPT_SHARE
  proc initClient() =
    var base: cstring
    var ssl: ptr sslConfig_t
    var keys: ptr list_t
    doAssert load_kube_config(cast[cstringArray](addr base), addr ssl, addr keys, nil) == 0, "cannot load kubeconfig"
    apiClient_setupGlobalEnv()
    api = apiClient_create_with_base_path(base, ssl, keys)
    when defined(cshare):
      share = curl_share_init()
      discard curl_share_setopt(share, 1.cint, 5.cint)                    # CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT
      api.curl_pre_invoke_func = preInvoke
  proc fetch(group, version, plural, cont: string): string =
    let g = genericClient_create(api, group.cstring, version.cstring, plural.cstring)
    let q = list_createList()
    let kvs = @[keyValuePair_create("limit", cast[pointer]("500".cstring))]
    list_addElement(q, kvs[0])
    var contKv: ptr keyValuePair_t = nil
    if cont.len > 0:
      contKv = keyValuePair_create("continue", cast[pointer](cont.cstring))
      list_addElement(q, contKv)
    let raw = Generic_list(g, q)
    if raw != nil:
      result = $raw
      c_free(raw)
    keyValuePair_free(kvs[0])
    if contKv != nil: keyValuePair_free(contKv)
    list_freeList(q)
    genericClient_free(g)
else:
  var kube: KubeClient
  var shared: HttpClient          # -d:thinfixed: one client and one SslContext for the whole process (keep-alive)
  proc initClient() = kube = inClusterKubeClient()
  proc fetch(group, version, plural, cont: string): string =
    let path = (if group.len == 0: "/api/" & version else: "/apis/" & group & "/" & version) & "/" & plural
    when defined(thinfixed):
      if shared.isNil:
        shared = newExporterHttpClient(token = kube.token, caPath = kube.caPath, certPath = kube.certPath,
                                       keyPath = kube.keyPath, insecure = kube.insecure)
      let response = shared.request(kube.baseUrl & listPathWithContinue(path, cont), httpMethod = HttpGet)
      if response.status[0] != '2': raise newException(IOError, "Kubernetes API returned " & response.status)
      response.body
    else:
      kube.apiGet(listPathWithContinue(path, cont))

proc cycle(): int =
  for (g, v, p) in resources:
    var cont = ""
    while true:
      let body = fetch(g, v, p, cont)
      var doc = readJson(body)
      defer: doc.close()
      for it in doc.root()["items"].items: inc result
      cont = doc.root()["metadata"].getStr("continue")
      if cont.len == 0: break

let n = parseInt(paramStr(1))
let t0 = epochTime()
initClient()
let baseline = rssKiB()
var samples: seq[int]
var items = 0
for i in 1 .. n:
  items = cycle()
  if i in [1, n div 3, 2 * n div 3, n]: samples.add rssKiB()
let dt = (epochTime() - t0) / toFloat(n)
echo (if defined(cshare): "official C client + shared connection cache" elif defined(cclient): "official C client" elif defined(thinfixed): "thin, one shared client" else: "thin std/httpclient, client per request (as in the exporter)"), ": items/cycle=", items, " cycle=", toInt(dt * 1000), " ms",
     " RSS KiB after init=", baseline, " after cycles 1,n/3,2n/3,n=", samples
