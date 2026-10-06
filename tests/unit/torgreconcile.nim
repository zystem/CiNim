## SHD-008: the reconciliation of the organisations with their Kubernetes objects, and the retention of a switched-off organisation,
## against a fake cluster that keeps objects in memory (no cluster, no database).
import std/[unittest, json, strutils, tables, sequtils, uri]
import ../../src/core/[kubeapi, orgprovision, orgreconcile, schema]
import ../../src/common/ctrlauth

type Cluster = ref object
  objects: Table[string, JsonNode]      ## path of the object -> the object
  calls: seq[string]                    ## "METHOD path"
  failPath: string                      ## a collection that answers 403

proc namespaceOf(path: string): string =
  ## "/api/v1/namespaces/<ns>/..." -> "<ns>"; "" when the path is not inside a namespace
  let parts = path.split('/')
  let i = parts.find("namespaces")
  if i >= 0 and i + 1 < parts.len: parts[i + 1] else: ""

proc api(f: Cluster): KubeApi =
  KubeApi(transport: proc (meth, path, body: string): tuple[code: int, body: string] =
    f.calls.add meth & " " & path
    case meth
    of "POST":
      if path == f.failPath: return (403, $(%*{"kind": "Status", "message": "forbidden: nope"}))
      let obj = parseJson(body)
      let p = path & "/" & obj["metadata"]["name"].getStr
      if p in f.objects: return (409, "{}")
      f.objects[p] = obj
      (201, "{}")
    of "DELETE":
      if path notin f.objects: return (404, "{}")
      f.objects.del path
      if path.startsWith("/api/v1/namespaces/") and path.count('/') == 4:
        let ns = path.split('/')[^1]
        for p in toSeq(f.objects.keys):
          if namespaceOf(p) == ns: f.objects.del p
      (200, "{}")
    of "GET":
      if path.startsWith("/api/v1/namespaces?labelSelector="):
        let sel = decodeUrl(path.split("labelSelector=")[1]).split('=')      # key=value
        var items = newJArray()
        for p, o in f.objects:
          if p.startsWith("/api/v1/namespaces/") and p.count('/') == 4 and o["metadata"]["labels"]{sel[0]}.getStr == sel[1]: items.add o
        return (200, $(%*{"items": items}))
      if path in f.objects: (200, $f.objects[path]) else: (404, "{}")
    else: (500, "{}"))

type Rec = ref object
  tokens, started, forgotten: seq[string]

proc hooksFor(r: Rec): Hooks =
  result.token = proc (namespace: string; rotate: bool): string =
    r.tokens.add namespace & (if rotate: ":rotated" else: ":kept")
    "TOKEN"
  result.startRetention = proc (slug: string; at: int64) = r.started.add slug
  result.forget = proc (slug, namespace: string) = r.forgotten.add slug & "@" & namespace

let curve = CurveKeys(corePub: "CP", clientPub: "LP", clientKey: "LK")

proc maker(build = false; multi = false): ConfigMaker =
  result = proc (egress, ingress: string): ProvisionConfig =
    ProvisionConfig(prefix: "cinim", shard: "001", shardNamespace: "cinim-001", controllerImage: "reg/ctl:1", build: build,
                    egressOpen: egress == "open", ingressOpen: ingress == "open", multi: multi, host: "ci.example.com", basePath: "/")

proc org(slug: string; state = "active"; disabledAt = 0'i64; egress = ""; ingress = ""): OrganizationFull =
  OrganizationFull(slug: slug, name: slug, state: state, egress: egress, ingress: ingress, disabledAt: disabledAt)

proc made(f: Cluster; mk: ConfigMaker; slug: string; active = true) =
  ## the objects of an organisation, as SHD-007 makes them, in the fake cluster
  discard provision(api(f), mk("", ""), slug, curve, "TOKEN", active)
  f.calls.setLen 0

proc ns(slug: string): string = "/api/v1/namespaces/cinim-001-" & slug

suite "SHD-008 reconciliation":
  test "an organisation whose objects are all there: nothing is made, nothing is deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.error == "" and r.orgs.len == 1 and r.orgs[0].created.len == 0 and r.orgs[0].error == ""
    check rec.tokens == @["cinim-001-acme:kept"] and not r.orgs[0].identityRenewed
    check f.calls.filterIt(it.startsWith("DELETE")).len == 0

  test "what is missing is made again with the same content, the rest is left alone":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let before = f.objects[ns("acme") & "/resourcequotas/cinim-default"]
    f.objects.del ns("acme") & "/resourcequotas/cinim-default"
    f.objects.del "/apis/apps/v1/namespaces/cinim-001-acme/deployments/cinim-job-controller"
    f.objects.del "/apis/networking.k8s.io/v1/namespaces/cinim-001-acme/networkpolicies/default-deny"
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created.len == 3 and "resource quota" in r.orgs[0].created and "controller" in r.orgs[0].created
    check "network policy default-deny" in r.orgs[0].created
    check f.objects[ns("acme") & "/resourcequotas/cinim-default"] == before
    check "/apis/apps/v1/namespaces/cinim-001-acme/deployments/cinim-job-controller" in f.objects

  test "a switched-off organisation is expected without its controller and its Ingress, and keeps the rest":
    let f = Cluster()
    let mkMulti = maker(multi = true)
    f.made(mkMulti, "old", active = false)
    check "/apis/apps/v1/namespaces/cinim-001-old/deployments/cinim-job-controller" notin f.objects
    check "/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-old" notin f.objects
    f.objects.del ns("old") & "/limitranges/cinim-default"
    let rec = Rec()
    let r = reconcilePass(api(f), mkMulti, curve, @[org("old", "disabled", 900)], hooksFor(rec), 1000, 100000)
    check r.orgs[0].created == @["limit range"]
    check "/apis/apps/v1/namespaces/cinim-001-old/deployments/cinim-job-controller" notin f.objects
    check "/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-old" notin f.objects

  test "an active organisation in the multi mode gets its Ingress back":
    let f = Cluster()
    let mkMulti = maker(multi = true)
    f.made(mkMulti, "acme")
    f.objects.del "/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-acme"
    let rec = Rec()
    let r = reconcilePass(api(f), mkMulti, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created == @["ingress"]

  test "a new cluster (the database was restored): every object is made, and the identity of the controller is renewed":
    let f = Cluster()
    let rec = Rec()
    let r = reconcilePass(api(f), maker(), curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].error == "" and "namespace" in r.orgs[0].created and "controller" in r.orgs[0].created
    check ns("acme") in f.objects
    check rec.tokens == @["cinim-001-acme:rotated"] and r.orgs[0].identityRenewed
    # the namespace was not there, so there was no old bootstrap Secret to replace
    check f.calls.filterIt(it.startsWith("DELETE")).len == 0

  test "the state volume of a controller is gone but the namespace is not: the identity is renewed and the bootstrap Secret replaced":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.objects.del ns("acme") & "/persistentvolumeclaims/cinim-job-controller-state"
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check rec.tokens == @["cinim-001-acme:rotated"] and r.orgs[0].identityRenewed
    check "controller state volume" in r.orgs[0].created
    check "DELETE " & ns("acme") & "/secrets/cinim-controller-bootstrap" in f.calls        # replaced: the core may create and delete Secrets, not change them
    check ns("acme") & "/secrets/cinim-controller-bootstrap" in f.objects

  test "the network mode asked for at creation is kept: an organisation with open egress gets its policy back":
    let f = Cluster()
    let mk = maker()
    discard provision(api(f), mk("open", "open"), "easy", curve, "TOKEN")
    f.objects.del "/apis/networking.k8s.io/v1/namespaces/cinim-001-easy/networkpolicies/allow-all-egress"
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("easy", egress = "open", ingress = "open")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created == @["network policy allow-all-egress"]

  test "a namespace of this shard that no organisation owns is an alert, and is never deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.made(mk, "ghost")
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.alerts.len == 1 and r.alerts[0].code == "orphan_namespace" and r.alerts[0].organization == "ghost" and r.alerts[0].namespace == "cinim-001-ghost"
    check ns("ghost") in f.objects
    check f.calls.filterIt(it.startsWith("DELETE")).len == 0
    # the namespace of another shard is not this shard's business
    f.objects["/api/v1/namespaces/cinim-002-x"] = %*{"metadata": {"name": "cinim-002-x", "labels": {"cinim.io/shard": "002", "cinim.io/organization": "x"}}}
    check reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100).alerts.len == 1

  test "a namespace that is being deleted is neither an orphan nor drift":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.made(mk, "going")
    f.objects[ns("going")]["metadata"]["deletionTimestamp"] = %"2026-10-06T17:12:00Z"
    f.objects[ns("acme")]["metadata"]["deletionTimestamp"] = %"2026-10-06T17:12:00Z"
    f.objects[ns("acme")]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] = %"privileged"
    let rec = Rec()
    check reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100).alerts.len == 0

  test "a namespace whose policy labels differ from the expected ones is an alert, and is left as it is":
    let f = Cluster()
    let mk = maker(build = true)
    f.made(mk, "acme")
    f.objects[ns("acme")]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] = %"privileged"
    f.objects[ns("acme")]["metadata"]["labels"].delete "cinim.io/build-pod-policy"
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.alerts.len == 2
    for a in r.alerts: check a.code == "namespace_drift" and a.organization == "acme"
    check "`privileged`, expected `baseline`" in r.alerts[0].detail or "`privileged`, expected `baseline`" in r.alerts[1].detail
    check f.objects[ns("acme")]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"].getStr == "privileged"

  test "an object the cluster refuses is reported for that organisation, the others are still reconciled":
    let f = Cluster(failPath: "/api/v1/namespaces/cinim-001-bad/secrets")
    let rec = Rec()
    let r = reconcilePass(api(f), maker(), curve, @[org("bad"), org("good")], hooksFor(rec), 1000, 100)
    check "forbidden: nope" in r.orgs[0].error and "controller keys" in r.orgs[0].error
    check r.orgs[1].error == "" and ns("good") in f.objects

  test "outside a cluster the pass says so and does nothing":
    let rec = Rec()
    let r = reconcilePass(KubeApi(), maker(), curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.error.len > 0 and r.orgs.len == 0

suite "SHD-007, SHD-008 retention of a switched-off organisation":
  test "the retention is over: the organisation is deleted for good (namespace and rows), one that is still within it is kept":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "gone", active = false)
    f.made(mk, "kept", active = false)
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("gone", "disabled", 100), org("kept", "disabled", 900)],
                          hooksFor(rec), 1000, 500)
    check r.purged == @["gone"] and rec.forgotten == @["gone@cinim-001-gone"]
    check ns("gone") notin f.objects and ns("kept") in f.objects
    check r.orgs.len == 1 and r.orgs[0].slug == "kept"
    check toSeq(f.objects.keys).filterIt(namespaceOf(it) == "cinim-001-gone").len == 0

  test "retention 0 deletes a switched-off organisation at once, a negative one never does":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "now", active = false)
    let rec = Rec()
    check reconcilePass(api(f), mk, curve, @[org("now", "disabled", 999)], hooksFor(rec), 1000, -1).purged.len == 0
    check ns("now") in f.objects
    check reconcilePass(api(f), mk, curve, @[org("now", "disabled", 999)], hooksFor(rec), 1000, 0).purged == @["now"]
    check ns("now") notin f.objects

  test "an organisation switched off before the time was recorded: the retention starts now, it is not deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "old", active = false)
    let rec = Rec()
    let r = reconcilePass(api(f), mk, curve, @[org("old", "disabled", 0)], hooksFor(rec), 1000, 500)
    check rec.started == @["old"] and r.purged.len == 0 and ns("old") in f.objects

  test "an active organisation is never deleted by the retention":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let rec = Rec()
    check reconcilePass(api(f), mk, curve, @[org("acme", "active", 1)], hooksFor(rec), 10_000_000, 0).purged.len == 0
    check ns("acme") in f.objects

  test "a failed deletion keeps the organisation and says why":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "gone", active = false)
    # the namespace cannot be deleted: make DELETE of it fail by answering 500 for its path
    let broken = KubeApi(transport: proc (meth, path, body: string): tuple[code: int, body: string] =
      if meth == "DELETE" and path == ns("gone"): return (403, $(%*{"message": "namespaces is forbidden"}))
      api(f).transport(meth, path, body))
    let rec = Rec()
    let r = reconcilePass(broken, mk, curve, @[org("gone", "disabled", 1)], hooksFor(rec), 1000, 10)
    check r.purged.len == 0 and rec.forgotten.len == 0
    check r.orgs.len >= 1 and "forbidden" in r.orgs[0].error
