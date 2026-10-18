## SHD-008: the reconciliation of the organisations in the database with the Kubernetes objects of SHD-007, and the retention of a
## switched-off organisation (SHD-007: `org_retention`).
##
## At start and every `org_reconcile_interval` the core makes again what is missing, with the same content: every create is idempotent
## ("already exists" is as good as a created one), so this is the provisioning of SHD-007 run once more for every organisation. It never
## deletes an object that it finds: an object that differs from the expected one, or that belongs to no organisation, is reported as an
## alert (`GET /api/v1/organizations:reconcile`), and objects go only with the explicit deletion of an organisation, or with the end of the
## retention of a switched-off one, which is the same deletion. What it can compare is limited by what the core may read: namespaces (their
## labels carry the policy, Pod Security and the build-pod policy) and the state volume of a controller; it may not read Secrets, so a
## Secret that was changed by hand is not noticed.
##
## The controller of an organisation is a Pod that the core itself makes, with the one-time token of the current generation of its identity in the environment (IAM-003, D-62);
## Kubernetes neither restarts it nor probes it. Every pass the core looks at the controller Pods of the namespace (`superviseController`): one that it does not know (another
## generation, another image or settings, ended, terminating, or the organisation is switched off) is deleted; one that did not enrol in time, or that was enrolled and has not
## been heard from for a while, is deleted too, and a new one is made with a new generation and its token. This is the whole of the controller's health.
##
## The decisions are a function of what the database and the cluster say (`reconcilePass`), with the database behind closures, so that
## `tests/unit/torgreconcile.nim` runs them against a fake cluster. `runPass` and `runReconciler` are the glue.
import std/[json, locks, atomics, os, strutils, times, algorithm]
import health
import kubeapi, orgprovision, schema, keptpods, ctrlpresence
import ../common/[rqlite, ctrlauth]

type
  ConfigMaker* = proc (egress, ingress: string): ProvisionConfig {.gcsafe.}   ## the objects of an organisation from the shard's settings and its own choice

  Hooks* = object
    identity*: proc (namespace: string): CredentialRow {.gcsafe.}               ## the identity of a namespace's controller (made if there is none)
    rotate*: proc (namespace: string) {.gcsafe.}                                ## a new generation: the old credential and token stop working
    token*: proc (namespace: string; generation: int): string {.gcsafe.}        ## the one-time token of a generation
    lastPoll*: proc (namespace: string): int64 {.gcsafe.}                       ## when the core last took in a report of that controller (0: not since the core started)
    startRetention*: proc (slug: string; at: int64) {.gcsafe.}
    forget*: proc (slug, namespace: string) {.gcsafe.}                          ## the rows of a deleted organisation

  OrgReport* = object
    slug*, state*: string
    created*: seq[string]          ## what was missing and has been made
    controllerReplaced*: bool      ## the controller's Pod was not the one the core makes now (a new image, new settings) and has been made again
    identityRenewed*: bool         ## a new generation of the controller's identity was made in this pass (the controller was not enrolled, was silent, or ended)
    controllerRemoved*: seq[string] ## "<Pod>: <why>" for every controller Pod the core deleted
    error*: string

  Alert* = object
    code*: string                  ## `orphan_namespace` (a namespace of this shard that no organisation owns) or `namespace_drift`
    namespace*, organization*, detail*: string

  PassResult* = object
    at*: int64
    orgs*: seq[OrgReport]
    alerts*: seq[Alert]
    purged*: seq[string]           ## organisations deleted for good at the end of their retention
    error*: string                 ## the pass could not run at all

const
  policyLabels = ["pod-security.kubernetes.io/enforce", "pod-security.kubernetes.io/audit", "pod-security.kubernetes.io/warn",
                  "cinim.io/build-pod-policy"]       ## the labels of a namespace that carry policy: a difference in these is an alert

const
  superviseEvery = 15      ## seconds between two looks at the controllers alone, between the full passes
  enrollGrace = 180        ## seconds a Running controller has to enrol with its token
  pendingGrace = 900       ## seconds a Pod that has not started (the image is pulled, the volume attached) is left alone
  silenceGrace = 120       ## seconds an enrolled controller may go without a report before the core calls it dead (it reports at least every 5 s)

proc createdAt(pod: JsonNode): int64 =
  ## the API server's time of the Pod's creation; 0 when it is not there (a clean 0 only makes the Pod look old: it is then judged by the reports alone)
  let ts = pod{"metadata", "creationTimestamp"}.getStr
  if ts.len == 0: return 0
  try: parse(ts, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime.toUnix
  except CatchableError: 0

proc controllerVerdict*(pod: JsonNode; id: CredentialRow; want: string; active: bool; now, coreStarted, lastPoll: int64): string =
  ## "" when this Pod is the controller the core wants, else why it is not. The core knows a controller by the generation of its identity and the fingerprint of what it makes:
  ## anything else it deleted (IAM-003, D-62).
  let phase = pod{"status", "phase"}.getStr("Pending")
  if pod{"metadata", "deletionTimestamp"} != nil: return "terminating"
  if not active: return "the organisation is switched off"
  if phase in ["Succeeded", "Failed"]: return "ended (" & phase & ")"
  let ann = pod{"metadata", "annotations"}
  if ann == nil or ann{generationAnnotation}.getStr != $id.generation: return "not the current generation of the identity (" & $id.generation & ")"
  if ann{specAnnotation}.getStr != want: return "replaced"          # another image or other settings than the core makes now
  let born = createdAt(pod)
  if not id.confirmed:
    let limit = if phase == "Pending": pendingGrace else: enrollGrace
    if born > 0 and now - born > limit: return "did not enrol with its token within " & $limit & " s"
  else:
    let heard = max(lastPoll, max(coreStarted, born))
    if now - heard > silenceGrace: return "not heard from for " & $(now - heard) & " s"
  ""

proc superviseController(k: KubeApi; cfg: ProvisionConfig; slug: string; active: bool; hooks: Hooks; now, coreStarted: int64; report: var OrgReport) =
  ## The controller is a Pod of the core (orgprovision.nim `newControllerPod`), and the core is its supervisor: it deletes the controller Pods it does not know, and when none is
  ## good, makes one with the one-time token of the identity; a new generation first when the identity has been used, has expired, or a Pod of this generation has just been
  ## deleted (its name is the generation's; the same token could not be given twice anyway).
  let ns = orgNamespace(cfg, slug)
  # a Deployment of the time before the controller became a Pod of the core (docs/compat.md): deleting it takes its Pods
  let old = k.remove("Deployment", ns, controllerName)
  if old.outcome == oFailed:
    report.error = "removing the Deployment of the controller: " & old.detail
    return
  if old.outcome == oDeleted: report.controllerRemoved.add "Deployment " & controllerName & ": replaced by a Pod of the core"
  let listed = k.listObjects("Pod", ns, "app.kubernetes.io/name=" & controllerName)
  if listed.error.len > 0:
    report.error = "listing the controller: " & listed.error
    return
  var id = hooks.identity(ns)
  let want = controllerSpecHash(cfg, slug)
  let poll = hooks.lastPoll(ns)
  var pods = listed.items
  pods.sort(proc (a, b: JsonNode): int = cmp(createdAt(b), createdAt(a)))       # the newest first: if two are good the older goes
  var haveGood, sawCurrent = false
  for pod in pods:
    let name = pod{"metadata", "name"}.getStr
    let current = pod{"metadata", "annotations", generationAnnotation}.getStr == $id.generation
    var why = controllerVerdict(pod, id, want, active, now, coreStarted, poll)
    if why.len == 0 and haveGood: why = "a second controller"
    if why.len == 0:
      haveGood = true
      continue
    if current: sawCurrent = true
    if why == "terminating": continue                                              # on its way out already
    let r = k.remove("Pod", ns, name)
    if r.outcome == oFailed:
      report.error = "deleting the controller " & name & ": " & r.detail
      return
    report.controllerRemoved.add name & ": " & why
    if why == "replaced": report.controllerReplaced = true
  if haveGood or not active: return
  if id.confirmed or id.bootstrapExpiresAt <= now or sawCurrent:
    hooks.rotate(ns)
    id = hooks.identity(ns)
    report.identityRenewed = true
  let made = k.create("Pod", ns, newControllerPod(cfg, slug, id.generation, hooks.token(ns, id.generation)))
  case made.outcome
  of oCreated: report.created.add "controller"
  of oFailed: report.error = "making the controller: " & made.detail
  else: discard

proc reconcileOne(k: KubeApi; cfg: ProvisionConfig; o: OrganizationFull; curve: CurveKeys; hooks: Hooks; now, coreStarted: int64): OrgReport =
  result = OrgReport(slug: o.slug, state: o.state)
  let ns = orgNamespace(cfg, o.slug)
  let active = o.state == "active"
  let nsGot = k.getObject("Namespace", "", ns)
  if nsGot.error.len > 0:
    result.error = "reading the namespace: " & nsGot.error
    return
  let r = provision(k, cfg, o.slug, curve, active)
  for s in r.steps:
    if s.outcome == oCreated: result.created.add s.name
  if not r.ok:
    result.error = r.failedStep & ": " & r.error
    return
  if cfg.controllerImage.len > 0: superviseController(k, cfg, o.slug, active, hooks, now, coreStarted, result)

proc namespaceAlerts(k: KubeApi; mk: ConfigMaker; orgs: seq[OrganizationFull]; shard: string): tuple[alerts: seq[Alert], error: string] =
  let l = k.listNamespaces("cinim.io/shard=" & shard)
  if l.error.len > 0: return (@[], "listing the namespaces: " & l.error)
  for it in l.items:
    if it{"metadata", "deletionTimestamp"} != nil: continue      # being deleted (the end of a retention, a purge): not an orphan, and no drift to report
    let name = it{"metadata", "name"}.getStr
    let labels = it{"metadata", "labels"}
    let slug = if labels != nil: labels{"cinim.io/organization"}.getStr else: ""
    if slug.len == 0: continue
    var known = false
    for o in orgs:
      if o.slug != slug: continue
      known = true
      let expected = namespaceLabels(mk(o.egress, o.ingress), slug)
      for key in policyLabels:
        let want = expected{key}.getStr
        let have = if labels != nil: labels{key}.getStr else: ""
        if want != have:
          result.alerts.add Alert(code: "namespace_drift", namespace: name, organization: slug,
                                  detail: key & " is " & (if have.len > 0: "`" & have & "`" else: "not set") & ", expected " &
                                          (if want.len > 0: "`" & want & "`" else: "not set"))
    if not known:
      result.alerts.add Alert(code: "orphan_namespace", namespace: name, organization: slug,
                              detail: "no organisation " & slug & " in this shard's database")

proc reconcilePass*(k: KubeApi; mk: ConfigMaker; curve: CurveKeys; orgs: seq[OrganizationFull]; hooks: Hooks; now, retention: int64;
                    coreStarted = 0'i64; purgeGrace = 0'i64): PassResult =
  ## One pass: first the retention (a switched-off organisation whose time is up is deleted for good; `retention` 0 is at once, below 0
  ## never), then the objects of every organisation that is left, then the alerts. A core that has just started deletes nothing for good: the retention of an organisation
  ## may have run out while the core was stopped, and its owner has had no chance to switch it on again; nothing is deleted before the core has been up for `purgeGrace`.
  result.at = now
  if not k.available:
    result.error = "the core does not run in a cluster, or CINIM_PROVISION is off"
    return
  var left: seq[OrganizationFull]
  for o0 in orgs:
    var o = o0
    if o.state == "disabled":
      if o.disabledAt == 0:
        hooks.startRetention(o.slug, now)       # switched off before the time was recorded: the retention runs from now
        o.disabledAt = now
      if o.held > 0 and retention >= 0 and now - o.disabledAt >= retention:
        # DAT-006: a legal hold forbids the deletion of what a run left; the organisation stays, switched off, until the holds are released
        result.orgs.add OrgReport(slug: o.slug, state: o.state, error: "not deleted at the end of the retention: " & $o.held & " run(s) under a legal hold (POST /api/v1/runs/{id}:release)")
      elif retention >= 0 and now - o.disabledAt >= retention and now - coreStarted >= purgeGrace:
        let cfg = mk(o.egress, o.ingress)
        let p = purge(k, cfg, o.slug)
        if p.ok:
          hooks.forget(o.slug, orgNamespace(cfg, o.slug))
          result.purged.add o.slug
          continue
        result.orgs.add OrgReport(slug: o.slug, state: o.state, error: "deleting at the end of the retention, " & p.failedStep & ": " & p.error)
    left.add o
  for o in left:
    result.orgs.add reconcileOne(k, mk(o.egress, o.ingress), o, curve, hooks, now, coreStarted)
  let a = namespaceAlerts(k, mk, left, mk("", "").shard)
  result.alerts = a.alerts
  if a.error.len > 0: result.error = a.error

proc superviseControllers*(k: KubeApi; mk: ConfigMaker; orgs: seq[OrganizationFull]; hooks: Hooks; now: int64; coreStarted = 0'i64): seq[OrgReport] =
  ## The part of a pass that the health of the controllers needs, run often (every 15 s, `runReconciler`) between the full passes: the controller Pods of every organisation
  ## that has a namespace, and nothing else. A silent controller is then noticed within minutes, not within the interval of the reconciliation.
  if not k.available: return
  for o in orgs:
    let cfg = mk(o.egress, o.ingress)
    if cfg.controllerImage.len == 0: continue
    let found = k.getObject("Namespace", "", orgNamespace(cfg, o.slug))
    if not found.found: continue                                  # nothing to supervise yet: the full pass makes the namespace
    var r = OrgReport(slug: o.slug, state: o.state)
    superviseController(k, cfg, o.slug, o.state == "active", hooks, now, coreStarted, r)
    if r.created.len > 0 or r.controllerRemoved.len > 0 or r.error.len > 0: result.add r

func toJson*(p: PassResult): JsonNode =
  var orgs = newJArray()
  for o in p.orgs:
    orgs.add %*{"slug": o.slug, "state": o.state, "created": o.created, "controller_replaced": o.controllerReplaced,
                "identity_renewed": o.identityRenewed, "controller_removed": o.controllerRemoved, "error": o.error}
  var alerts = newJArray()
  for a in p.alerts:
    alerts.add %*{"code": a.code, "namespace": a.namespace, "organization": a.organization, "detail": a.detail}
  %*{"at": p.at, "organizations": orgs, "alerts": alerts, "deleted": p.purged, "error": p.error}

# ------------------------------------------------------------------ the glue: the database, the cluster, a thread

type
  PassEnv* = object
    rqliteUrl*, certs*: string
    mk*: ConfigMaker
    interval*, retention*: int64      ## seconds between two passes; seconds a switched-off organisation is kept (0: deleted at once, below 0: never deleted)
    coreStarted*, purgeGrace*: int64  ## when this core started, and how long it must have been up before it deletes an organisation for good (CINIM_ORG_PURGE_GRACE, a day)
    bootstrapTtl*: int64

var
  lock: Lock                          ## guards `lastJson`; `passLock` lets one pass run at a time (the timer and `POST ...:reconcile`)
  passLock: Lock
  lastJson: string
  runNow: Atomic[bool]
initLock(lock)
initLock(passLock)

proc lastPassJson*(): string =
  {.cast(gcsafe).}:
    withLock lock: result = lastJson

proc requestPass*() =
  runNow.store(true)

proc makeHooks(e: PassEnv; master: string): Hooks =
  {.cast(gcsafe).}:
    result = Hooks(
        identity: proc (namespace: string): CredentialRow =
          var db = newRq(e.rqliteUrl)
          db.ensureCredentialRow(namespace, getTime().toUnix() + e.bootstrapTtl)
          db.credentialRow(namespace),
        rotate: proc (namespace: string) =
          var db = newRq(e.rqliteUrl)
          db.rotateCredential(namespace, getTime().toUnix() + e.bootstrapTtl),
        token: proc (namespace: string; generation: int): string = bootstrapToken(master, namespace, generation),
        lastPoll: proc (namespace: string): int64 = ctrlpresence.lastPoll(namespace),
        startRetention: proc (slug: string; at: int64) =
          var db = newRq(e.rqliteUrl)
          db.startRetention(slug, at),
        forget: proc (slug, namespace: string) =
          var db = newRq(e.rqliteUrl)
          db.deleteCredentialRow(namespace)
          forgetPolls(namespace)
          forgetKept(namespace)
          db.deleteOrganization(slug))


proc runPass*(e: PassEnv; kube: KubeApi): PassResult =
  {.cast(gcsafe).}:
    withLock passLock:
      var c = newRq(e.rqliteUrl)
      let hooks = makeHooks(e, coreSecret(e.certs))
      result = reconcilePass(kube, e.mk, loadCurve(e.certs), c.listOrganizationsFull(), hooks, getTime().toUnix(), e.retention, e.coreStarted, e.purgeGrace)
      withLock lock: lastJson = $result.toJson

proc runSupervision*(e: PassEnv; kube: KubeApi): seq[OrgReport] =
  ## the health of the controllers alone (`superviseControllers`)
  {.cast(gcsafe).}:
    withLock passLock:
      var c = newRq(e.rqliteUrl)
      result = superviseControllers(kube, e.mk, c.listOrganizationsFull(), makeHooks(e, coreSecret(e.certs)), getTime().toUnix(), e.coreStarted)

proc runReconciler*(args: tuple[env: PassEnv, stop: ptr Atomic[bool]]) {.thread.} =
  ## SHD-008: a pass at start and then every `interval` seconds, or when asked (`requestPass`); the thread has a client of its own
  {.cast(gcsafe).}:
    let kube = inCluster()
    var waited = args.env.interval * 10        # the first pass at once
    while not args.stop[].load:
      beat(bReconciler)
      if runNow.exchange(false) or waited >= args.env.interval * 10:
        waited = 0
        try:
          let r = runPass(args.env, kube)
          if r.error.len > 0: stderr.writeLine "core: reconciliation: " & r.error
          for o in r.orgs:
            if o.created.len > 0: echo "core: reconciliation made again for ", o.slug, ": ", o.created.join(", ")
            for g in o.controllerRemoved: echo "core: the controller of ", o.slug, ": deleted ", g
            if o.error.len > 0: stderr.writeLine "core: reconciliation of " & o.slug & ": " & o.error
          for s in r.purged: echo "core: the retention of the organisation ", s, " is over, deleted"
        except CatchableError as e:
          stderr.writeLine "core: reconciliation failed: " & e.msg
      elif waited mod (superviseEvery * 10) == 0 and kube.available:
        try:
          for o in runSupervision(args.env, kube):
            if o.created.len > 0: echo "core: the controller of ", o.slug, ": made again"
            for g in o.controllerRemoved: echo "core: the controller of ", o.slug, ": deleted ", g
            if o.error.len > 0: stderr.writeLine "core: supervision of the controller of " & o.slug & ": " & o.error
        except CatchableError as e:
          stderr.writeLine "core: supervision of the controllers failed: " & e.msg
      sleep 100
      inc waited
