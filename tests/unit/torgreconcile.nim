## SHD-008: the reconciliation of the organisations with their Kubernetes objects, and the retention of a switched-off organisation,
## against a fake cluster that keeps objects in memory (no cluster, no database).
import std/[unittest, json, strutils, tables, sequtils, uri, times]
import ../../src/core/[kubeapi, orgprovision, orgreconcile, schema]
import ../../src/common/ctrlauth

const t0 = 1_700_000_000'i64          ## the "now" of the supervision tests
proc iso(t: int64): string = fromUnix(t).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

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
      if "/pods?labelSelector=" in path:
        let prefix = path.split('?')[0]
        let sel = decodeUrl(path.split("labelSelector=")[1]).split('=')
        var items = newJArray()
        for p, o in f.objects:
          if p.startsWith(prefix & "/") and o["metadata"]["labels"]{sel[0]}.getStr == sel[1]: items.add o
        return (200, $(%*{"items": items}))
      if path in f.objects: (200, $f.objects[path]) else: (404, "{}")
    else: (500, "{}"))

type Rec = ref object
  started, forgotten: seq[string]
  generation: int                  ## the identity of the controller as the database has it
  confirmed: bool
  expires: int64
  poll: int64                      ## when the controller was last heard
  rotations: int

proc newRec(): Rec = Rec(generation: 1, expires: t0 + 86400)

proc hooksFor(r: Rec): Hooks =
  result.identity = proc (namespace: string): CredentialRow =
    CredentialRow(found: true, generation: r.generation, confirmed: r.confirmed, bootstrapExpiresAt: r.expires)
  result.rotate = proc (namespace: string) =
    inc r.generation
    inc r.rotations
    r.confirmed = false
    r.expires = t0 + 86400
  result.token = proc (namespace: string; generation: int): string = "TOKEN-" & $generation
  result.lastPoll = proc (namespace: string): int64 = r.poll
  result.startRetention = proc (slug: string; at: int64) = r.started.add slug
  result.forget = proc (slug, namespace: string) = r.forgotten.add slug & "@" & namespace

let curve = CurveKeys(corePub: "CP", clientPub: "LP", clientKey: "LK")

proc maker(build = false; multi = false; image = "reg/ctl:1"): ConfigMaker =
  result = proc (egress, ingress: string): ProvisionConfig =
    ProvisionConfig(prefix: "cinim", shard: "001", shardNamespace: "cinim-001", controllerImage: image, build: build,
                    egressOpen: egress == "open", ingressOpen: ingress == "open", multi: multi, host: "ci.example.com", basePath: "/")

proc org(slug: string; state = "active"; disabledAt = 0'i64; egress = ""; ingress = ""): OrganizationFull =
  OrganizationFull(slug: slug, name: slug, state: state, egress: egress, ingress: ingress, disabledAt: disabledAt)

proc podAt(f: Cluster; slug: string; name: string): string = "/api/v1/namespaces/cinim-001-" & slug & "/pods/" & name

proc controllerPod(f: Cluster; mk: ConfigMaker; slug: string; generation = 1; born = 990'i64; phase = "Running"; image = ""): string =
  ## a controller Pod as the core made it and the cluster has aged it; returns its path
  var c = mk("", "")
  let own = c.controllerImage
  if image.len > 0: c.controllerImage = image
  var pod = newControllerPod(c, slug, generation, "TOKEN-" & $generation)
  if image.len > 0: pod["metadata"]["annotations"]["cinim.io/controller-spec"] = %controllerSpecHash(c, slug)
  discard own
  pod["metadata"]["creationTimestamp"] = %iso(born)
  pod["status"] = %*{"phase": phase}
  result = f.podAt(slug, pod["metadata"]["name"].getStr)
  f.objects[result] = pod

proc made(f: Cluster; mk: ConfigMaker; slug: string; active = true; controller = true) =
  ## the objects of an organisation, as SHD-007 makes them, in the fake cluster, and a controller that has just been started (generation 1, not yet enrolled)
  discard provision(api(f), mk("", ""), slug, curve, active)
  if active and controller and mk("", "").controllerImage.len > 0: discard f.controllerPod(mk, slug)
  f.calls.setLen 0

proc ns(slug: string): string = "/api/v1/namespaces/cinim-001-" & slug

proc deletes(f: Cluster): seq[string] = f.calls.filterIt(it.startsWith("DELETE") and "/deployments/" notin it)      # the Deployment of the time before is asked for every pass

proc specOf(mk: ConfigMaker; slug: string): string = controllerSpecHash(mk("", ""), slug)

suite "IAM-003, D-62 the core supervises the controller: a Pod of its own, with the one-time token of the generation in its environment":
  let ctl = "/api/v1/namespaces/cinim-001-acme/pods/cinim-job-controller-"
  proc pods(f: Cluster): seq[string] = toSeq(f.objects.keys).filterIt("/pods/" in it)
  proc tokenOf(f: Cluster; path: string): string =
    for e in f.objects[path]["spec"]["containers"][0]["env"]:
      if e["name"].getStr == "CINIM_BOOTSTRAP_TOKEN": return e["value"].getStr
  proc pass(f: Cluster; mk: ConfigMaker; rec: Rec; state = "active"; coreStarted = 0'i64; slug = "acme"): PassResult =
    reconcilePass(api(f), mk, curve, @[org(slug, state, (if state == "disabled": 900 else: 0))], hooksFor(rec), t0, -1, coreStarted)

  test "an organisation with no controller gets a Pod named by the generation, with the token of that generation; the identity is not rotated for a token that has not been used":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    let rec = newRec()
    let r = f.pass(mk, rec)
    check r.orgs[0].error == "" and r.orgs[0].created == @["controller"] and not r.orgs[0].identityRenewed and rec.rotations == 0
    check (ctl & "1") in f.objects and f.tokenOf(ctl & "1") == "TOKEN-1"
    check f.objects[ctl & "1"]["metadata"]["annotations"]["cinim.io/generation"].getStr == "1"
  test "a controller that has just started and is not enrolled yet is left alone, and so is a Pod that is still being scheduled for a while":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", born = t0 - 100)
    let rec = newRec()
    let r = f.pass(mk, rec)
    check r.orgs[0].created.len == 0 and r.orgs[0].controllerRemoved.len == 0 and f.deletes.len == 0
    f.objects[ctl & "1"]["metadata"]["creationTimestamp"] = %iso(t0 - 600)
    f.objects[ctl & "1"]["status"]["phase"] = %"Pending"                      # the image is being pulled: not the controller's fault
    check f.pass(mk, rec).orgs[0].controllerRemoved.len == 0
  test "a controller that did not enrol with its token in time is deleted and another is started with a new generation and its token":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", born = t0 - 300)
    let rec = newRec()
    let r = f.pass(mk, rec)
    check r.orgs[0].controllerRemoved.len == 1 and "did not enrol" in r.orgs[0].controllerRemoved[0]
    check (ctl & "1") notin f.objects and (ctl & "2") in f.objects and f.tokenOf(ctl & "2") == "TOKEN-2"
    check rec.rotations == 1 and r.orgs[0].identityRenewed and r.orgs[0].created == @["controller"]
  test "an enrolled controller that is heard from is left alone; one that has been silent is killed and replaced, and the new one gets a new generation":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", born = t0 - 3600)
    let rec = newRec()
    rec.confirmed = true
    rec.poll = t0 - 5
    check f.pass(mk, rec).orgs[0].controllerRemoved.len == 0 and f.deletes.len == 0
    rec.poll = t0 - 500
    let r = f.pass(mk, rec)
    check r.orgs[0].controllerRemoved.len == 1 and "not heard from" in r.orgs[0].controllerRemoved[0]
    check (ctl & "1") notin f.objects and f.tokenOf(ctl & "2") == "TOKEN-2" and rec.rotations == 1
  test "a core that has just started has heard nobody: the controllers get the time to report before they are called silent":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", born = t0 - 3600)
    let rec = newRec()
    rec.confirmed = true                              # no report heard since the core started (poll 0)
    check f.pass(mk, rec, coreStarted = t0 - 30).orgs[0].controllerRemoved.len == 0
    check f.pass(mk, rec, coreStarted = t0 - 300).orgs[0].controllerRemoved.len == 1
  test "a Pod of another generation is not the controller the core knows: it is deleted, and the Pod of the current generation is made (a rotation by the administrator)":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", generation = 1, born = t0 - 3600)
    let rec = newRec()
    rec.generation = 2                                # rotated: the token of generation 2 is unspent
    let r = f.pass(mk, rec)
    check r.orgs[0].controllerRemoved.len == 1 and "not the current generation" in r.orgs[0].controllerRemoved[0]
    check (ctl & "1") notin f.objects and f.tokenOf(ctl & "2") == "TOKEN-2" and rec.rotations == 0
  test "a Pod that has ended, a controller the core did not make, and a second good one are deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", generation = 1, phase = "Failed")
    let rec = newRec()
    var r = f.pass(mk, rec)
    check "ended" in r.orgs[0].controllerRemoved[0] and (ctl & "2") in f.objects and rec.rotations == 1       # a Pod of this generation was seen: not the same token twice
    let stranger = ctl & "stranger"
    f.objects[stranger] = %*{"metadata": {"name": "cinim-job-controller-stranger", "labels": {"app.kubernetes.io/name": "cinim-job-controller"}}, "status": {"phase": "Running"}}
    r = f.pass(mk, rec)
    check r.orgs[0].controllerRemoved.anyIt("cinim-job-controller-stranger" in it) and stranger notin f.objects and (ctl & "2") in f.objects
    discard f.controllerPod(mk, "acme", generation = 2, born = t0 - 50)           # two Pods of the one generation cannot both be: the newer stays
    f.objects[ctl & "2"]["metadata"]["name"] = %"cinim-job-controller-2"
    f.objects[ctl & "2b"] = f.objects[ctl & "2"].copy
    f.objects[ctl & "2b"]["metadata"]["name"] = %"cinim-job-controller-2b"
    f.objects[ctl & "2b"]["metadata"]["creationTimestamp"] = %iso(t0 - 100)
    r = f.pass(mk, rec)
    check r.orgs[0].controllerRemoved == @["cinim-job-controller-2b: a second controller"]
  test "a Pod being deleted is not deleted again, and does not keep the core from starting the one that replaces it":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme")
    f.objects[ctl & "1"]["metadata"]["deletionTimestamp"] = %iso(t0 - 5)
    let rec = newRec()
    let r = f.pass(mk, rec)
    check f.deletes.len == 0
    check (ctl & "2") in f.objects and rec.rotations == 1
  test "a new image: the Pod made with the old one is deleted and the controller is made again with the new one; the state is on its volume":
    let f = Cluster()
    let old = maker()
    f.made(old, "acme", controller = false)
    discard f.controllerPod(old, "acme", born = t0 - 3600)
    let fresh = maker(image = "reg/ctl:2")
    let rec = newRec()
    rec.confirmed = true
    rec.poll = t0 - 1
    let r = f.pass(fresh, rec)
    check r.orgs[0].controllerReplaced and r.orgs[0].controllerRemoved == @["cinim-job-controller-1: replaced"]
    check f.objects[ctl & "2"]["spec"]["containers"][0]["image"].getStr == "reg/ctl:2"
    check f.pass(fresh, rec).orgs[0].controllerRemoved.len == 0            # the new one is the one wanted
  test "the settings of the shard are not part of the Pod: a build profile does not replace the controller":
    let f = Cluster()
    f.made(maker(build = false), "acme", controller = false)
    discard f.controllerPod(maker(build = false), "acme", born = t0 - 3600)
    let rec = newRec()
    rec.confirmed = true
    rec.poll = t0 - 1
    check not f.pass(maker(build = true), rec).orgs[0].controllerReplaced
  test "an unspent token that has expired is not used: the identity is rotated first":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    let rec = newRec()
    rec.expires = t0 - 1
    let r = f.pass(mk, rec)
    check rec.rotations == 1 and f.tokenOf(ctl & "2") == "TOKEN-2" and r.orgs[0].identityRenewed
  test "a used identity is rotated for the next controller (the old credential and token stop working)":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    let rec = newRec()
    rec.confirmed = true
    discard f.pass(mk, rec)
    check rec.rotations == 1 and f.tokenOf(ctl & "2") == "TOKEN-2" and not rec.confirmed
  test "a switched-off organisation keeps no controller: its Pods are deleted and none is made":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", active = false)
    discard f.controllerPod(mk, "acme", born = t0 - 10)
    let rec = newRec()
    let r = f.pass(mk, rec, state = "disabled")
    check r.orgs[0].controllerRemoved.len == 1 and "switched off" in r.orgs[0].controllerRemoved[0] and f.pods.len == 0 and r.orgs[0].created.len == 0
  test "the Deployment of the time before the controller was a Pod is deleted, with its Pods":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    f.objects["/apis/apps/v1/namespaces/cinim-001-acme/deployments/cinim-job-controller"] = %*{"metadata": {"name": "cinim-job-controller"}}
    let rec = newRec()
    let r = f.pass(mk, rec)
    check "/apis/apps/v1/namespaces/cinim-001-acme/deployments/cinim-job-controller" notin f.objects
    check r.orgs[0].controllerRemoved.anyIt(it.startsWith("Deployment cinim-job-controller"))
  test "a Pod that cannot be listed or deleted is told, and nothing is made then":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    let blind = KubeApi(transport: proc (meth, path, body: string): tuple[code: int, body: string] =
      if meth == "GET" and "/pods?" in path: return (403, $(%*{"message": "pods is forbidden"}))
      api(f).transport(meth, path, body))
    let r = reconcilePass(blind, mk, curve, @[org("acme")], hooksFor(newRec()), t0, 100)
    check "listing the controller" in r.orgs[0].error and f.pods.len == 0
  test "the supervision alone (between the full passes) replaces a silent controller, touches nothing else, and skips an organisation that has no namespace yet":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme", controller = false)
    discard f.controllerPod(mk, "acme", born = t0 - 3600)
    f.objects.del ns("acme") & "/resourcequotas/cinim-default"                   # a full pass would make it again; this one must not
    let rec = newRec()
    rec.confirmed = true
    rec.poll = t0 - 500
    let r = superviseControllers(api(f), mk, @[org("acme"), org("new")], hooksFor(rec), t0)
    check r.len == 1 and r[0].slug == "acme" and r[0].created == @["controller"] and r[0].controllerRemoved.len == 1
    check (ctl & "2") in f.objects and (ns("acme") & "/resourcequotas/cinim-default") notin f.objects
    check superviseControllers(api(f), mk, @[org("acme")], hooksFor(rec), t0).len == 0          # healthy now: nothing to report
  test "without a controller image the core supervises nothing":
    let f = Cluster()
    let mk = maker(image = "")
    f.made(mk, "acme")
    let r = f.pass(mk, newRec())
    check r.orgs[0].error == "" and f.pods.len == 0 and f.calls.filterIt("/pods" in it).len == 0

suite "SHD-008 a NetworkPolicy that differs from what the core makes now is replaced":
  let dns = "/apis/networking.k8s.io/v1/namespaces/cinim-001-acme/networkpolicies/allow-dns-and-collector"
  test "policies the core made are left alone: the fingerprint they carry is the one it would make":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(newRec()), 1000, 100)
    check r.orgs[0].policiesReplaced.len == 0 and f.deletes.len == 0
    check f.objects[dns]["metadata"]["annotations"]["cinim.io/spec-hash"].getStr.len == 24
  test "a policy that carries another fingerprint (the rules of the core changed: a port, the network mode) is deleted and made again with the new content":
    let f = Cluster()
    let old = maker()
    f.made(old, "acme")
    let fresh: ConfigMaker = proc (egress, ingress: string): ProvisionConfig {.gcsafe.} =
      {.cast(gcsafe).}: result = old(egress, ingress)
      result.storageDirectPort = 18091                      # a rule the policy did not have when it was made
    let r = reconcilePass(api(f), fresh, curve, @[org("acme")], hooksFor(newRec()), 1000, 100)
    check r.orgs[0].policiesReplaced == @["allow-dns-and-collector"] and r.orgs[0].error == ""
    let at = f.calls.find("DELETE " & dns)
    check at >= 0 and "POST /apis/networking.k8s.io/v1/namespaces/cinim-001-acme/networkpolicies" in f.calls[at + 1 .. ^1]       # deleted, then made again
    var ports: seq[int]
    for rule in f.objects[dns]["spec"]["egress"]:
      for p in rule{"ports"}.getElems: ports.add p["port"].getInt
    check 18091 in ports
    check reconcilePass(api(f), fresh, curve, @[org("acme")], hooksFor(newRec()), 1000, 100).orgs[0].policiesReplaced.len == 0       # and then it is the one wanted
  test "a policy made before the fingerprint existed has none: it is replaced once":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.objects[dns]["metadata"].delete "annotations"
    check reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(newRec()), 1000, 100).orgs[0].policiesReplaced == @["allow-dns-and-collector"]
  test "a policy that is missing is made, not counted as replaced":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.objects.del dns
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(newRec()), 1000, 100)
    check r.orgs[0].policiesReplaced.len == 0 and "network policy allow-dns-and-collector" in r.orgs[0].created
  test "a refusal to delete or to read a policy is told for that organisation":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.objects[dns]["metadata"]["annotations"]["cinim.io/spec-hash"] = %"stale"
    let denying = KubeApi(transport: proc (meth, path, body: string): tuple[code: int, body: string] =
      if meth == "DELETE" and path == dns: return (403, $(%*{"message": "forbidden: delete"}))
      api(f).transport(meth, path, body))
    let r = reconcilePass(denying, mk, curve, @[org("acme")], hooksFor(newRec()), 1000, 100)
    check "replacing network policy allow-dns-and-collector" in r.orgs[0].error and r.orgs[0].policiesReplaced.len == 0

suite "SHD-008 reconciliation":
  test "an organisation whose objects are all there: nothing is made, nothing is deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.error == "" and r.orgs.len == 1 and r.orgs[0].created.len == 0 and r.orgs[0].error == ""
    check not r.orgs[0].identityRenewed and r.orgs[0].controllerRemoved.len == 0
    check f.deletes.len == 0

  test "what is missing is made again with the same content, the rest is left alone":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let before = f.objects[ns("acme") & "/resourcequotas/cinim-default"]
    f.objects.del ns("acme") & "/resourcequotas/cinim-default"
    f.objects.del "/apis/networking.k8s.io/v1/namespaces/cinim-001-acme/networkpolicies/default-deny"
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created.len == 2 and "resource quota" in r.orgs[0].created
    check "network policy default-deny" in r.orgs[0].created
    check f.objects[ns("acme") & "/resourcequotas/cinim-default"] == before

  test "a switched-off organisation is expected without its controller and its Ingress, and keeps the rest":
    let f = Cluster()
    let mkMulti = maker(multi = true)
    f.made(mkMulti, "old", active = false)
    check "/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-old" notin f.objects
    f.objects.del ns("old") & "/limitranges/cinim-default"
    let rec = newRec()
    let r = reconcilePass(api(f), mkMulti, curve, @[org("old", "disabled", 900)], hooksFor(rec), 1000, 100000)
    check r.orgs[0].created == @["limit range"]
    check toSeq(f.objects.keys).filterIt("/pods/" in it).len == 0
    check "/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-old" notin f.objects

  test "an active organisation in the multi mode gets its Ingress back":
    let f = Cluster()
    let mkMulti = maker(multi = true)
    f.made(mkMulti, "acme")
    f.objects.del "/apis/networking.k8s.io/v1/namespaces/cinim-001/ingresses/org-acme"
    let rec = newRec()
    let r = reconcilePass(api(f), mkMulti, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created == @["ingress"]

  test "a new cluster (the database was restored): every object is made, and a controller is started with a token of the generation the database has":
    let f = Cluster()
    let rec = newRec()
    let r = reconcilePass(api(f), maker(), curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].error == "" and "namespace" in r.orgs[0].created and "controller" in r.orgs[0].created
    check ns("acme") in f.objects and ns("acme") & "/pods/cinim-job-controller-1" in f.objects
    check f.deletes.len == 0
  test "the state volume of a controller is gone: it is made again, and the controller, which keeps no credential on it, is not touched":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.objects.del ns("acme") & "/persistentvolumeclaims/cinim-job-controller-state"
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created == @["controller state volume"] and rec.rotations == 0

  test "the network mode asked for at creation is kept: an organisation with open egress gets its policy back":
    let f = Cluster()
    let mk = maker()
    discard provision(api(f), mk("open", "open"), "easy", curve)
    discard f.controllerPod(mk, "easy")
    f.objects.del "/apis/networking.k8s.io/v1/namespaces/cinim-001-easy/networkpolicies/allow-all-egress"
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("easy", egress = "open", ingress = "open")], hooksFor(rec), 1000, 100)
    check r.orgs[0].created == @["network policy allow-all-egress"]

  test "a namespace of this shard that no organisation owns is an alert, and is never deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    f.made(mk, "ghost")
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.alerts.len == 1 and r.alerts[0].code == "orphan_namespace" and r.alerts[0].organization == "ghost" and r.alerts[0].namespace == "cinim-001-ghost"
    check ns("ghost") in f.objects
    check f.deletes.len == 0
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
    let rec = newRec()
    check reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100).alerts.len == 0

  test "a namespace whose policy labels differ from the expected ones is an alert, and is left as it is":
    let f = Cluster()
    let mk = maker(build = true)
    f.made(mk, "acme")
    f.objects[ns("acme")]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] = %"privileged"
    f.objects[ns("acme")]["metadata"]["labels"].delete "cinim.io/build-pod-policy"
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.alerts.len == 2
    for a in r.alerts: check a.code == "namespace_drift" and a.organization == "acme"
    check "`privileged`, expected `baseline`" in r.alerts[0].detail or "`privileged`, expected `baseline`" in r.alerts[1].detail
    check f.objects[ns("acme")]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"].getStr == "privileged"

  test "an object the cluster refuses is reported for that organisation, the others are still reconciled":
    let f = Cluster(failPath: "/api/v1/namespaces/cinim-001-bad/secrets")
    let rec = newRec()
    let r = reconcilePass(api(f), maker(), curve, @[org("bad"), org("good")], hooksFor(rec), 1000, 100)
    check "forbidden: nope" in r.orgs[0].error and "controller keys" in r.orgs[0].error
    check r.orgs[1].error == "" and ns("good") in f.objects

  test "outside a cluster the pass says so and does nothing":
    let rec = newRec()
    let r = reconcilePass(KubeApi(), maker(), curve, @[org("acme")], hooksFor(rec), 1000, 100)
    check r.error.len > 0 and r.orgs.len == 0

suite "SHD-007, SHD-008 retention of a switched-off organisation":
  test "the retention is over: the organisation is deleted for good (namespace and rows), one that is still within it is kept":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "gone", active = false)
    f.made(mk, "kept", active = false)
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("gone", "disabled", 100), org("kept", "disabled", 900)],
                          hooksFor(rec), 1000, 500)
    check r.purged == @["gone"] and rec.forgotten == @["gone@cinim-001-gone"]
    check ns("gone") notin f.objects and ns("kept") in f.objects
    check r.orgs.len == 1 and r.orgs[0].slug == "kept"
    check toSeq(f.objects.keys).filterIt(namespaceOf(it) == "cinim-001-gone").len == 0

  test "DAT-006 an organisation with a run under a legal hold is not deleted for good at the end of its retention, and says why; one without is":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "held", active = false)
    f.made(mk, "free", active = false)
    let rec = newRec()
    var heldOrg = org("held", "disabled", 100)
    heldOrg.held = 2
    let r = reconcilePass(api(f), mk, curve, @[heldOrg, org("free", "disabled", 100)], hooksFor(rec), 1000, 500)
    check r.purged == @["free"] and ns("held") in f.objects and ns("free") notin f.objects
    check r.orgs.anyIt(it.slug == "held" and "legal hold" in it.error and "2 run" in it.error)
    heldOrg.held = 0
    check reconcilePass(api(f), mk, curve, @[heldOrg], hooksFor(rec), 1000, 500).purged == @["held"]       # released: the next pass deletes it

  test "retention 0 deletes a switched-off organisation at once, a negative one never does":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "now", active = false)
    let rec = newRec()
    check reconcilePass(api(f), mk, curve, @[org("now", "disabled", 999)], hooksFor(rec), 1000, -1).purged.len == 0
    check ns("now") in f.objects
    check reconcilePass(api(f), mk, curve, @[org("now", "disabled", 999)], hooksFor(rec), 1000, 0).purged == @["now"]
    check ns("now") notin f.objects

  test "an organisation switched off before the time was recorded: the retention starts now, it is not deleted":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "old", active = false)
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("old", "disabled", 0)], hooksFor(rec), 1000, 500)
    check rec.started == @["old"] and r.purged.len == 0 and ns("old") in f.objects

  test "an active organisation is never deleted by the retention":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "acme")
    let rec = newRec()
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
    let rec = newRec()
    let r = reconcilePass(broken, mk, curve, @[org("gone", "disabled", 1)], hooksFor(rec), 1000, 10)
    check r.purged.len == 0 and rec.forgotten.len == 0
    check r.orgs.len >= 1 and "forbidden" in r.orgs[0].error

suite "SHD-008 a core that has just started deletes no organisation for good":
  test "the retention is over, but the core has not been up for the grace: the organisation stays, and goes once the grace has passed":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "late", active = false)
    let rec = newRec()
    # the retention ended long ago (500 s from 100), the core started at 990 and the grace is 3600 s
    let early = reconcilePass(api(f), mk, curve, @[org("late", "disabled", 100)], hooksFor(rec), 1000, 500, coreStarted = 990, purgeGrace = 3600)
    check early.purged.len == 0 and ns("late") in f.objects
    let later = reconcilePass(api(f), mk, curve, @[org("late", "disabled", 100)], hooksFor(rec), 4600, 500, coreStarted = 990, purgeGrace = 3600)
    check later.purged == @["late"] and ns("late") notin f.objects
  test "an organisation that is kept for the grace is still reconciled like any other":
    let f = Cluster()
    let mk = maker()
    f.made(mk, "late", active = false)
    let rec = newRec()
    let r = reconcilePass(api(f), mk, curve, @[org("late", "disabled", 100)], hooksFor(rec), 1000, 500, coreStarted = 990, purgeGrace = 3600)
    check r.orgs.len == 1 and r.orgs[0].slug == "late"
