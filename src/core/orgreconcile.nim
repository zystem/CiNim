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
## An organisation whose namespace is missing (the database was restored into a new cluster) or whose controller lost its state volume has
## lost the identity of its controller (IAM-003, the credential lived on that volume): its generation is rotated and the bootstrap token
## replaced, and the controller enrols again.
##
## The decisions are a function of what the database and the cluster say (`reconcilePass`), with the database behind closures, so that
## `tests/unit/torgreconcile.nim` runs them against a fake cluster. `runPass` and `runReconciler` are the glue.
import std/[json, locks, atomics, os, strutils, times]
import kubeapi, orgprovision, schema
import ../common/[rqlite, ctrlauth]

type
  ConfigMaker* = proc (egress, ingress: string): ProvisionConfig {.gcsafe.}   ## the objects of an organisation from the shard's settings and its own choice

  Hooks* = object
    token*: proc (namespace: string; rotate: bool): string {.gcsafe.}           ## the bootstrap token of a namespace's controller; a new generation first when `rotate`
    startRetention*: proc (slug: string; at: int64) {.gcsafe.}
    forget*: proc (slug, namespace: string) {.gcsafe.}                          ## the rows of a deleted organisation

  OrgReport* = object
    slug*, state*: string
    created*: seq[string]          ## what was missing and has been made
    identityRenewed*: bool
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

proc reconcileOne(k: KubeApi; cfg: ProvisionConfig; o: OrganizationFull; curve: CurveKeys; hooks: Hooks): OrgReport =
  result = OrgReport(slug: o.slug, state: o.state)
  let ns = orgNamespace(cfg, o.slug)
  let active = o.state == "active"
  let nsGot = k.getObject("Namespace", "", ns)
  if nsGot.error.len > 0:
    result.error = "reading the namespace: " & nsGot.error
    return
  var identityLost = not nsGot.found
  if nsGot.found and cfg.controllerImage.len > 0:
    let pvc = k.getObject("PersistentVolumeClaim", ns, stateClaimName)
    if pvc.error.len > 0:
      result.error = "reading the state volume: " & pvc.error
      return
    identityLost = not pvc.found
  var token = ""
  if cfg.controllerImage.len > 0:
    token = hooks.token(ns, identityLost)
    result.identityRenewed = identityLost
    if identityLost and nsGot.found:
      # the Secret of the old bootstrap token is still there; the core may create and delete Secrets, not change them
      let r = renewBootstrapSecret(k, cfg, o.slug, token)
      if not r.ok:
        result.error = r.failedStep & ": " & r.error
        return
  let r = provision(k, cfg, o.slug, curve, token, active)
  for s in r.steps:
    if s.outcome == oCreated: result.created.add s.name
  if not r.ok: result.error = r.failedStep & ": " & r.error

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

proc reconcilePass*(k: KubeApi; mk: ConfigMaker; curve: CurveKeys; orgs: seq[OrganizationFull]; hooks: Hooks; now, retention: int64): PassResult =
  ## One pass: first the retention (a switched-off organisation whose time is up is deleted for good; `retention` 0 is at once, below 0
  ## never), then the objects of every organisation that is left, then the alerts.
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
      if retention >= 0 and now - o.disabledAt >= retention:
        let cfg = mk(o.egress, o.ingress)
        let p = purge(k, cfg, o.slug)
        if p.ok:
          hooks.forget(o.slug, orgNamespace(cfg, o.slug))
          result.purged.add o.slug
          continue
        result.orgs.add OrgReport(slug: o.slug, state: o.state, error: "deleting at the end of the retention, " & p.failedStep & ": " & p.error)
    left.add o
  for o in left:
    result.orgs.add reconcileOne(k, mk(o.egress, o.ingress), o, curve, hooks)
  let a = namespaceAlerts(k, mk, left, mk("", "").shard)
  result.alerts = a.alerts
  if a.error.len > 0: result.error = a.error

func toJson*(p: PassResult): JsonNode =
  var orgs = newJArray()
  for o in p.orgs:
    orgs.add %*{"slug": o.slug, "state": o.state, "created": o.created, "identity_renewed": o.identityRenewed, "error": o.error}
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

proc runPass*(e: PassEnv; kube: KubeApi): PassResult =
  {.cast(gcsafe).}:
    withLock passLock:
      var c = newRq(e.rqliteUrl)
      let master = coreSecret(e.certs)
      let hooks = Hooks(
        token: proc (namespace: string; rotate: bool): string =
          var db = newRq(e.rqliteUrl)
          let expires = getTime().toUnix() + e.bootstrapTtl
          db.ensureCredentialRow(namespace, expires)
          if rotate: db.rotateCredential(namespace, expires)
          bootstrapToken(master, namespace, db.credentialRow(namespace).generation),
        startRetention: proc (slug: string; at: int64) =
          var db = newRq(e.rqliteUrl)
          db.startRetention(slug, at),
        forget: proc (slug, namespace: string) =
          var db = newRq(e.rqliteUrl)
          db.deleteCredentialRow(namespace)
          db.deleteOrganization(slug))
      result = reconcilePass(kube, e.mk, loadCurve(e.certs), c.listOrganizationsFull(), hooks, getTime().toUnix(), e.retention)
      withLock lock: lastJson = $result.toJson

proc runReconciler*(args: tuple[env: PassEnv, stop: ptr Atomic[bool]]) {.thread.} =
  ## SHD-008: a pass at start and then every `interval` seconds, or when asked (`requestPass`); the thread has a client of its own
  {.cast(gcsafe).}:
    let kube = inCluster()
    var waited = args.env.interval * 10        # the first pass at once
    while not args.stop[].load:
      if runNow.exchange(false) or waited >= args.env.interval * 10:
        waited = 0
        try:
          let r = runPass(args.env, kube)
          if r.error.len > 0: stderr.writeLine "core: reconciliation: " & r.error
          for o in r.orgs:
            if o.created.len > 0: echo "core: reconciliation made again for ", o.slug, ": ", o.created.join(", ")
            if o.error.len > 0: stderr.writeLine "core: reconciliation of " & o.slug & ": " & o.error
          for s in r.purged: echo "core: the retention of the organisation ", s, " is over, deleted"
        except CatchableError as e:
          stderr.writeLine "core: reconciliation failed: " & e.msg
      sleep 100
      inc waited
