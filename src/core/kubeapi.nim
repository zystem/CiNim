## A thin Kubernetes REST client for the core (SHD-007): create and delete JSON objects with the Pod's ServiceAccount token and CA.
## The core needs a dozen kinds and nothing else (no list, no watch), so this is a few requests over std/httpclient (the pattern of the
## in-cluster client in the user's k8s-image-availability-exporter) instead of the C client of the job controller, which would pull
## libcurl and a second TLS stack into the static core. The transport is a parameter so the tests run without a cluster.
import std/[json, httpclient, net, os, strutils, uri]

const
  saDir = "/var/run/secrets/kubernetes.io/serviceaccount"

type
  KubeTransport* = proc (meth, path, body: string): tuple[code: int, body: string] {.closure.}

  KubeApi* = object
    transport*: KubeTransport   ## nil: there is no cluster (the core runs outside Kubernetes, or provisioning is off)

  Outcome* = enum
    oCreated, oExists, oDeleted, oAbsent, oFailed

  KubeResult* = object
    outcome*: Outcome
    code*: int
    detail*: string             ## the API server's message when it failed

func available*(k: KubeApi): bool = k.transport != nil

# The kinds the core creates: the REST collection of each (namespaced ones take the namespace).
func collectionPath*(kind, namespace: string): string =
  let ns = "/namespaces/" & namespace
  case kind
  of "Namespace": "/api/v1/namespaces"
  of "ServiceAccount": "/api/v1" & ns & "/serviceaccounts"
  of "Secret": "/api/v1" & ns & "/secrets"
  of "PersistentVolumeClaim": "/api/v1" & ns & "/persistentvolumeclaims"
  of "ResourceQuota": "/api/v1" & ns & "/resourcequotas"
  of "LimitRange": "/api/v1" & ns & "/limitranges"
  of "Deployment": "/apis/apps/v1" & ns & "/deployments"
  of "RoleBinding": "/apis/rbac.authorization.k8s.io/v1" & ns & "/rolebindings"
  of "NetworkPolicy": "/apis/networking.k8s.io/v1" & ns & "/networkpolicies"
  of "Ingress": "/apis/networking.k8s.io/v1" & ns & "/ingresses"
  else: raise newException(ValueError, "the core does not handle objects of kind " & kind)

func objectPath*(kind, namespace, name: string): string =
  collectionPath(kind, namespace) & "/" & name

proc message(body: string; code: int): string =
  ## the API server answers a failure with a Status object; its `message` is what a person needs
  try:
    let j = parseJson(body)
    if j.kind == JObject and j.hasKey("message"): return j["message"].getStr
  except CatchableError:
    discard
  "HTTP " & $code

proc create*(k: KubeApi; kind, namespace: string; obj: JsonNode): KubeResult =
  ## 201 is created; 409 (AlreadyExists) is as good: creating again is how a retry and the reconciliation work
  let r = k.transport("POST", collectionPath(kind, namespace), $obj)
  case r.code
  of 200, 201, 202: KubeResult(outcome: oCreated, code: r.code)
  of 409: KubeResult(outcome: oExists, code: r.code)
  else: KubeResult(outcome: oFailed, code: r.code, detail: message(r.body, r.code))

proc getObject*(k: KubeApi; kind, namespace, name: string): tuple[found: bool, obj: JsonNode, error: string] =
  ## reading what the core itself made, for the reconciliation (SHD-008); only the kinds that its ClusterRole lets it read are asked for
  ## (namespaces, and the ones that `get` is granted on in the chart). error "" with found false is a clean 404
  let r = k.transport("GET", objectPath(kind, namespace, name), "")
  case r.code
  of 200:
    try: (true, parseJson(r.body), "")
    except CatchableError: (false, nil, "the answer was not JSON")
  of 404: (false, nil, "")
  else: (false, nil, message(r.body, r.code))

proc listNamespaces*(k: KubeApi; labelSelector: string): tuple[items: seq[JsonNode], error: string] =
  ## the namespaces with a label, as the API returns them (the core may `list` namespaces)
  let r = k.transport("GET", "/api/v1/namespaces?labelSelector=" & encodeUrl(labelSelector), "")
  if r.code != 200: return (@[], message(r.body, r.code))
  try:
    for it in parseJson(r.body){"items"}: result.items.add it
  except CatchableError:
    result.error = "the answer was not JSON"

proc remove*(k: KubeApi; kind, namespace, name: string): KubeResult =
  ## 404 is as good as a delete: the object is gone either way
  let r = k.transport("DELETE", objectPath(kind, namespace, name), "")
  case r.code
  of 200, 202: KubeResult(outcome: oDeleted, code: r.code)
  of 404: KubeResult(outcome: oAbsent, code: r.code)
  else: KubeResult(outcome: oFailed, code: r.code, detail: message(r.body, r.code))

when defined(ssl):
  proc inClusterTransport(host, port, tokenFile, caFile: string): KubeTransport =
    result = proc (meth, path, body: string): tuple[code: int, body: string] =
      # the token is read on every request: a projected ServiceAccount token is rotated by the kubelet (about hourly)
      let client = newHttpClient(timeout = 15000, sslContext = newContext(verifyMode = CVerify_Peer, caFile = caFile))
      defer: client.close()
      client.headers = newHttpHeaders({"Authorization": "Bearer " & readFile(tokenFile).strip, "Content-Type": "application/json",
                                       "Accept": "application/json"})
      let m = case meth
        of "POST": HttpPost
        of "DELETE": HttpDelete
        of "GET": HttpGet
        else: raise newException(ValueError, "unsupported method " & meth)
      let r = client.request("https://" & host & ":" & port & path, httpMethod = m, body = body)
      (r.code.int, r.body)

proc inCluster*(): KubeApi =
  ## the Pod's own ServiceAccount; no transport (not available) when there is none, i.e. outside a cluster, or in a build without TLS
  when defined(ssl):
    let host = getEnv("KUBERNETES_SERVICE_HOST")
    let port = getEnv("KUBERNETES_SERVICE_PORT", "443")
    if host.len == 0 or not fileExists(saDir / "token") or not fileExists(saDir / "ca.crt"): return
    KubeApi(transport: inClusterTransport(if ':' in host: "[" & host & "]" else: host, port, saDir / "token", saDir / "ca.crt"))
  else:
    KubeApi()

proc ownNamespace*(): string =
  ## the namespace this Pod runs in (the namespace of the shard); "" outside a cluster
  if fileExists(saDir / "namespace"): readFile(saDir / "namespace").strip else: ""
