## REST API of core (9.1): runs (POST /api/v1/runs, GET /api/v1/runs/{id} with the steps' attempts, states and the reason each
## ended the way it did), the bare step-log read (GET /api/v1/runs/{id}/steps/{seq}/log; from/around/search/tail/download are later
## slices, DAT-007), the launch gate, the execution profile's settings (GET/PUT /api/v1/profile, docs/settings.md), the component
## list (/api/v1/components) and Prometheus metrics (/metrics, docs/metrics.md). Bearer tokens (apiauth.nim, IAM-003; OIDC/RBAC are not implemented yet); `group`
## and `script` (Lua source) are accepted directly in the body since there is no directory, no repositories and no blob storage yet.
##
## HTTP layer: GuildenStern (D-25): pure Nim, no C dependency. Its `onRequest` is one global dispatcher
## reading thread-local request state via `getUri`/`getMethod`/`getBody`, so routes are matched here, by hand.
import std/[json, os, strutils, uri, times, atomics, tables, httpclient, options, sets]
import ../common/httpsrv
import ../common/scriptsource
import oidc, mfa, vcsapprove, accesscode, auditexport, prstatus, approvals, teams, ldapauth, projectpolicy, audit, joblocks, orgvars, pwcheck, runlist, runrequest, runstorage, scheduler, loggate, logcircuit, retrypolicy, schema, orgrules, routerclient, kubeapi, orgprovision, orgreconcile, logwindow, keptpods, apiauth, stepsecrets, secretvault, vaultsetup, runparams, triggers, objectstore, groups, holds, cachestore, varaudit, preflight
import ../common/[ctrlauth, envname, luaapi]
import ../common/rqlite
import ../common/dbready
import health

let mfaPolicy = getEnv("CINIM_MFA_REQUIRE_FOR").toLowerAscii          ## D-101: "admin" or "all": who must have a second factor
let mfaIssuer = getEnv("CINIM_MFA_ISSUER", "CiNim")
let clientAddrHeaderName = getEnv("CINIM_CLIENT_ADDR_HEADER")          ## D-97: the header in which the proxy in front puts the address of the client (empty: the logins are not throttled by address)

const base = "/api/v1/runs"
const maxDownloadBytes = 64 * 1024 * 1024

proc problem(status: HttpCode; code, detail: string) =
  reply(status, $(%*{"type": "about:blank", "status": ord(status), "code": code, "detail": detail}),
    ["Content-Type: application/problem+json"])

proc jsonOk(status: HttpCode; body: JsonNode) =
  reply(status, $body, ["Content-Type: application/json"])

proc withLabel(label: JsonNode; extra: JsonNode): JsonNode =
  result = newJObject()
  for k, v in label.pairs: result[k] = v
  for k, v in extra.pairs: result[k] = v

type VarAudit = object
  ## what a change of a variable needs to be in the audit (VAR-006): the organisation (empty for the shard), how the level is named in the record, the key of the digests, who acts
  tenantId, level, master: string
  who: Principal

proc serveVariables(vc: var RqClient; scope: VarScope; key, varName: string; label: JsonNode; au: VarAudit) =
  ## The variables of one level (VAR-001, core/orgvars.nim): GET lists them, PUT and DELETE name one (`/variables/{NAME}`). `label` says whose they are in the answers.
  ## A change is in the audit when the organisation asks for it (VAR-006, core/varaudit.nim).
  let vmeth = getMethod()
  if vmeth == "GET" and varName.len == 0:
    var list = newJArray()
    for (k, v) in vc.listScopeVariables(scope, key): list.add %*{"name": k, "value": v}
    jsonOk(Http200, withLabel(label, %*{"variables": list}))
  elif varName.len == 0:
    problem(Http405, "method_not_allowed", "GET lists, PUT and DELETE name a variable: /variables/{NAME}")
  elif vmeth == "PUT":
    let vj = try: parseJson(getBody()) except JsonParsingError: nil
    if not vj.isString("value"):
      problem(Http400, "invalid_request", "{\"value\": \"...\"} is required")
      return
    let was = vc.scopeVariable(scope, key, varName)
    let bad = vc.setScopeVariable(scope, key, varName, vj["value"].getStr, getTime().toUnix())
    if bad.len > 0:
      problem(Http400, "invalid_variable", bad)
      return
    vc.recordVariable(vc.variableAuditMode(au.tenantId), au.master, au.tenantId, getTime().toUnix(), au.who, au.level, varName, was, some(vj["value"].getStr))
    jsonOk(Http200, withLabel(label, %*{"name": varName, "value": vj["value"].getStr}))
  elif vmeth == "DELETE":
    let was = vc.scopeVariable(scope, key, varName)
    if not vc.deleteScopeVariable(scope, key, varName):
      problem(Http404, "not_found", "no such variable")
      return
    vc.recordVariable(vc.variableAuditMode(au.tenantId), au.master, au.tenantId, getTime().toUnix(), au.who, au.level, varName, was, none(string))
    jsonOk(Http200, withLabel(label, %*{"name": varName, "deleted": true}))
  else:
    problem(Http405, "method_not_allowed", "GET, PUT or DELETE")


proc serveScopeHold(hc: var RqClient; orgId, slug, groupId, groupPath: string; who: Principal) =
  ## A legal hold on the organisation (`groupId` '') or on a group (DAT-006, core/holds.nim): GET shows it, PUT places it with a reason (`rw`, `admin`), DELETE releases it.
  ## It covers every run of the organisation, or of the group and the groups below it, those that exist and those made while it stands.
  let label = if groupPath.len == 0: %*{"organization": slug} else: %*{"organization": slug, "group": groupPath}
  let target = if groupPath.len == 0: slug else: slug & "/" & groupPath
  let kind = if groupPath.len == 0: "organization" else: "group"
  let meth = getMethod()
  if meth == "GET":
    var h = hc.scopeHoldOf(orgId, groupId)
    h.hold.groupPath = groupPath
    jsonOk(Http200, withLabel(label, %*{"held": h.held, "hold": (if h.held: h.hold.view else: newJNull())}))
  elif meth == "PUT":
    let hj = try: parseJson(getBody()) except JsonParsingError: nil
    if not hj.isString("reason"):
      problem(Http400, "invalid_request", "{\"reason\": \"...\"} is required: a legal hold has a reason")
      return
    let reason = hj["reason"].getStr
    let placed = hc.placeScopeHold(orgId, groupId, reason, actorOf(who), getTime().toUnix())
    if placed.error.len > 0:
      problem(Http400, "invalid_hold", placed.error)
      return
    if placed.placed: hc.record(getTime().toUnix(), actorOf(who), kind & ".hold", target, "ok", reason[0 ..< min(200, reason.len)])
    var h = hc.scopeHoldOf(orgId, groupId)
    h.hold.groupPath = groupPath
    jsonOk(if placed.placed: Http201 else: Http200, withLabel(label, %*{"held": true, "hold": h.hold.view, "placed": placed.placed}))
  elif meth == "DELETE":
    let gone = hc.releaseScopeHold(orgId, groupId)
    if gone: hc.record(getTime().toUnix(), actorOf(who), kind & ".release", target, "ok")
    jsonOk(Http200, withLabel(label, %*{"held": false, "released": gone}))
  else:
    problem(Http405, "method_not_allowed", "GET, PUT or DELETE")

let
  orgShard = getEnv("CINIM_SHARD", "001")                  ## the name of this shard: digits only (SHD-001)
  orgPrefix = getEnv("CINIM_NAMESPACE_PREFIX", "cinim")    ## the namespace prefix (SHD-001)
  metricsOn = getEnv("CINIM_METRICS", "true") != "false"   ## the Helm value `metrics.enabled` (SPEC section 15); false makes /metrics a 404

let
  pwnedCfg = pwnedConfigFromEnv()               ## IAM-001: the check of a chosen password against Pwned Passwords (core/pwcheck.nim)
  adminToken = getEnv("CINIM_ADMIN_TOKEN")      ## a token of the operator's own (IAM-003); empty: the first start makes one and writes it to the log
  authOn* = adminToken.len > 0 or getEnv("CINIM_AUTH") == "on"     ## otherwise the API is open (development)

proc unauthorized(why: string) =
  reply(Http401, $(%*{"type": "about:blank", "status": 401, "code": "unauthorized", "detail": "a valid API token is required (" & why & ")"}),
    ["Content-Type: application/problem+json", "WWW-Authenticate: Bearer"])

var coreRef: Core   ## set once at startup (main.nim); read-only after that, one HTTP thread pool

let
  kube = inCluster()   ## the Pod's ServiceAccount; not available outside a cluster, and the organisation then is a record only
  provisionOn = kube.available and getEnv("CINIM_PROVISION", "auto") != "off"
  deployOn = getEnv("CINIM_DEPLOY", "off") == "on"    ## the shard has a deploy profile (D-48): the namespace of every organisation gets the policies of its Pods
  buildOn = getEnv("CINIM_BUILD", "off") == "on"      ## the shard has a build profile: the namespace of every organisation allows build Pods (A.13, D-42)
  bootstrapTtl = parseInt(getEnv("CINIM_CONTROLLER_BOOTSTRAP_TTL", "86400"))   ## seconds a bootstrap token of a controller stays good

proc networkDefaults(): tuple[egress, ingress: string] =
  ## SHD-009: what an organisation gets when it asks for nothing: the chart's `network.egress` (`restricted`, `open`) and `network.ingress`
  ## (`closed`, `open`)
  result.egress = if getEnv("CINIM_NETWORK_EGRESS") == "open": "open" else: "restricted"
  result.ingress = if getEnv("CINIM_NETWORK_INGRESS") == "open": "open" else: "closed"

proc directPort(): int =
  ## D-61: the port of the storage module for shims, from CINIM_STORAGE_DIRECT_URL (http://host:port); 0 when the shard has none
  let u = getEnv("CINIM_STORAGE_DIRECT_URL")
  if u.len == 0: return 0
  try: parseUri(u).port.parseInt except ValueError: 0

proc provisionConfig(cfg: RouterConfig; egress = ""; ingress = ""): ProvisionConfig =
  ## SHD-007: what the objects of an organisation are made from. In the `multi` mode (a router is configured) the core also makes
  ## the Ingress <basePath>/<slug>/ of the organisation; the host and the base path are those of the public URL.
  let pub = parseUri(cfg.publicBase)
  var annotations: JsonNode
  try:
    let raw = getEnv("CINIM_INGRESS_ANNOTATIONS")
    if raw.len > 0: annotations = parseJson(raw)
  except JsonParsingError:
    discard
  var buildEgress: JsonNode
  try:
    let raw = getEnv("CINIM_BUILD_EGRESS")
    if raw.len > 0: buildEgress = parseJson(raw)
  except JsonParsingError:
    discard
  var buildIngress: JsonNode
  try:
    let raw = getEnv("CINIM_BUILD_INGRESS")
    if raw.len > 0: buildIngress = parseJson(raw)
  except JsonParsingError:
    discard
  var deployEgress: JsonNode
  try:
    let raw = getEnv("CINIM_DEPLOY_EGRESS")
    if raw.len > 0: deployEgress = parseJson(raw)
  except JsonParsingError:
    discard
  var buildInternet: JsonNode
  try:
    let raw = getEnv("CINIM_BUILD_INTERNET")
    if raw.len > 0 and raw != "off": buildInternet = parseJson(raw)
  except JsonParsingError:
    discard
  var conductorEgress, conductorInternet: JsonNode
  try:
    let raw = getEnv("CINIM_CONDUCTOR_EGRESS")
    if raw.len > 0: conductorEgress = parseJson(raw)
    let net = getEnv("CINIM_CONDUCTOR_INTERNET")
    if net.len > 0 and net != "off": conductorInternet = parseJson(net)
  except JsonParsingError:
    discard
  let nd = networkDefaults()
  ProvisionConfig(prefix: orgPrefix, shard: orgShard, shardNamespace: ownNamespace(), buildInternet: buildInternet, conductorEgress: conductorEgress, conductorInternet: conductorInternet,
                  egressOpen: (if egress.len > 0: egress else: nd.egress) == "open", ingressOpen: (if ingress.len > 0: ingress else: nd.ingress) == "open",
                  storageDirectPort: directPort(), build: buildOn, buildEgress: buildEgress, stepEphemeralLimit: getEnv("CINIM_STEP_EPHEMERAL_LIMIT"), buildIngress: buildIngress,
                  deploy: deployOn, deployEgress: deployEgress, conductors: conductorImage.len > 0, deployKubeApiServer: getEnv("CINIM_DEPLOY_KUBE_APISERVER") == "true",
                  controllerImage: getEnv("CINIM_CONTROLLER_IMAGE"), stateClass: getEnv("CINIM_CONTROLLER_STATE_CLASS"),
                  multi: cfg.url.len > 0, host: pub.hostname, basePath: pub.path,
                  ingressClass: getEnv("CINIM_INGRESS_CLASS"), tlsSecret: getEnv("CINIM_INGRESS_TLS_SECRET"), annotations: annotations)

proc reconcileEnv(co: Core): PassEnv =
  ## SHD-008: what a pass needs; the settings are the Helm values `organizations.reconcileInterval` and `organizations.retention`
  PassEnv(rqliteUrl: co.rqliteUrl, certs: co.certs, bootstrapTtl: bootstrapTtl,
          mk: proc (egress, ingress: string): ProvisionConfig {.gcsafe.} =
            {.cast(gcsafe).}: provisionConfig(currentConfig(), egress, ingress),
          interval: max(10, parseInt(getEnv("CINIM_ORG_RECONCILE_INTERVAL", "300"))),
          retention: parseBiggestInt(getEnv("CINIM_ORG_RETENTION", $(14 * 86400))),
          coreStarted: runstorage.coreStartedAt, purgeGrace: parseBiggestInt(getEnv("CINIM_ORG_PURGE_GRACE", $(86400))))

var reconcilerThread: Thread[tuple[env: PassEnv, stop: ptr Atomic[bool]]]
var reconcilerRunning = false

proc startReconciler*(co: Core) =
  ## SHD-008: the reconciliation and the retention run only where the core can reach a cluster
  if not provisionOn: return
  createThread(reconcilerThread, runReconciler, (reconcileEnv(co), addr stopServers))
  reconcilerRunning = true
  echo "core: reconciling the organisations every ", reconcileEnv(co).interval, " s, a switched-off one is kept ", reconcileEnv(co).retention, " s"

proc joinReconciler*() =
  if reconcilerRunning: joinThread(reconcilerThread)

proc stepsJson(r: ProvisionResult): JsonNode =
  result = newJArray()
  for s in r.steps: result.add %*{"step": s.name, "outcome": ($s.outcome)[1 .. ^1].toLowerAscii}

proc onRequest() {.raises: [], gcsafe.} =
  # newHttpServer's callback type is itself `raises: []` (the E-004 rule - no exception crosses the handler boundary - is
  # enforced by the compiler here) - every exception funnels through the one try/except below.
  # coreRef is set once at startup and read-only after that (see its declaration) - the gcsafe cast below
  # is for the compiler's benefit, not a real race (same pattern as scheduler.nim's stopServers).
  {.cast(gcsafe).}:
    try:
      let uri = getUri()
      let qpos = uri.find('?')
      let path = if qpos >= 0: uri[0 ..< qpos] else: uri
      if path == "/metrics":
        if not metricsOn:
          problem(Http404, "not_found", "metrics are turned off")
          return
        reply(Http200, coreRef.renderCoreMetrics(), ["Content-Type: text/plain; version=0.0.4; charset=utf-8"])
        return
      if path == "/healthz":
        # the liveness probe of the Pod, which needs no token: alive, and none of the threads that take the log, the reports and the artifacts is stuck (core/health.nim)
        let live = livenessJson(epochTime())
        if live.ok: jsonOk(Http200, live.body)
        else: reply(Http503, $live.body, ["Content-Type: application/json"])
        return
      if path == "/readyz":
        # the readiness probe: the database answers (common/dbready.nim). Not ready is alive: the Pod is left out of the Service until the database is back, and not restarted
        let db = readyCached(coreRef.rqliteUrl, 2000, epochTime())
        if db.ok: jsonOk(Http200, %*{"status": "ready", "checks": {"database": "ok"}})
        else: reply(Http503, $(%*{"status": "not_ready", "checks": {"database": db.why}}), ["Content-Type: application/json"])
        return
      if path.startsWith("/api/v1/vcs/"):
        # D-100: the host of a project\'s repository tells what its reviewers say. It is no API token: the call is signed with the secret named in the project\'s status.webhook_secret, and
        # a stranger is told nothing of which projects there are (the same answer for every reason). POST /api/v1/vcs/{organization}/{project path}
        let notThere = proc () = problem(Http404, "not_found", "no such webhook, or the signature is not right")
        if getMethod() != "POST":
          problem(Http405, "method_not_allowed", "POST")
          return
        let vrest = path["/api/v1/vcs/".len .. ^1]
        let vslash = vrest.find('/')
        if vslash <= 0 or vslash == vrest.high:
          notThere()
          return
        let vslug = vrest[0 ..< vslash]
        var vc = newRq(coreRef.rqliteUrl)
        let vorg = vc.organizationRow(vslug)
        let vproj = if vorg.id.len > 0: vc.resolveProject(vorg.id, vrest[vslash + 1 .. ^1]) else: ResolvedProject(code: "x")
        if vproj.code.len > 0:
          notThere()
          return
        let vt = vc.statusTargetOf(vproj.id)
        let vk = vaultKek()
        if vt.provider.len == 0 or vt.webhookSecret.len == 0 or not vk.ready:
          notThere()
          return
        let vsec = vc.getSecrets(vk.kek, vorg.id, @[vt.webhookSecret], vproj.id, true)
        if not vsec.ok or vsec.values.len == 0:
          notThere()
          return
        let vraw = getRequest()
        let vbody = getBody()
        let signed = if vt.provider == "github": verifyGithub(vsec.values[0][1], vbody, headerOfRaw(vraw, "x-hub-signature-256"))
                     else: verifyGitlab(vsec.values[0][1], headerOfRaw(vraw, "x-gitlab-token"))
        if not signed:
          notThere()
          return
        let vj = try: parseJson(vbody) except JsonParsingError: nil
        var ev = if vt.provider == "github": parseGithub(headerOfRaw(vraw, "x-github-event"), vj) else: parseGitlab(headerOfRaw(vraw, "x-gitlab-event"), vj)
        if not ev.relevant or ev.repository.toLowerAscii != vt.repository.toLowerAscii:
          jsonOk(Http202, %*{"ignored": "this event asks for nothing"})
          return
        if ev.sha.len == 0 and ev.prNumber > 0:
          let tok = vc.getSecrets(vk.kek, vorg.id, @[vt.secret], vproj.id, true)
          ev.sha = if tok.ok and tok.values.len > 0: prHead(vt, tok.values[0][1], ev.prNumber) else: ""
          if ev.sha.len == 0:
            problem(Http502, "host_unreachable", "the commit of the pull request could not be asked of the host (status.secret)")
            return
        let vres = vc.answerFromHost(vorg.id, vslug, vproj.id, vproj.path, vt.provider, ev, getTime().toUnix())
        jsonOk(HttpCode(vres.status), vres.body)
        return
      if path.startsWith("/api/v1/hooks/"):
        # a webhook is called with the secret of its own trigger, which is no API token (core/triggers.nim): it starts that trigger's run and nothing else
        if getMethod() != "POST":
          problem(Http405, "method_not_allowed", "POST")
          return
        var hc = newRq(coreRef.rqliteUrl)
        let hook = hc.authenticateHook(path["/api/v1/hooks/".len .. ^1], bearerOf(getRequest()))
        if not hook.ok:
          problem(Http404, "not_found", "no such webhook, or the secret is not its own")      # the same answer for both: an id is not confirmed to a stranger
          return
        if not hook.row.enabled:
          problem(Http409, "trigger_disabled", "this trigger is switched off")
          return
        let body = getBody()
        let bj = if body.strip.len == 0: newJObject() else: (try: parseJson(body) except JsonParsingError: nil)
        if bj == nil or bj.kind != JObject:
          problem(Http400, "invalid_request", "the body is empty or {\"commit\": \"...\"}")
          return
        # D-63: a webhook carries no launch parameters; it names the commit to run (core/triggers.nim hookCommit)
        let said = hookCommit(bj, hook.row)
        if said.error.len > 0:
          problem(Http400, "invalid_request", said.error)
          return
        let wanted = said.commit
        let fired = coreRef.fire(hook.row, @[], getTime().toUnix(), commit = wanted)
        if fired.started:
          jsonOk(Http201, %*{"id": fired.runId, "organization": hook.row.slug, "trigger_id": hook.row.id, "state": coreRef.stateOfRun(fired.runId)})
        elif fired.status != 0:
          problem(HttpCode(fired.status), fired.reason, fired.detail)
        else:
          problem((if fired.reason == "queue_full": Http429 else: Http409), fired.reason, "no run was started: " & fired.reason)
        return
      if path.startsWith("/api/v1/oidc/") and getMethod() in ["GET", "POST"] and (path == "/api/v1/oidc/callback" or path.endsWith("/start")):
        # D-102: the login by an OpenID Connect provider (core/oidc.nim). GET /oidc/{organization}/{provider}/start gives the address of the provider\'s login page; the browser comes back to the UI, which
        # gives the state and the code to POST /oidc/callback and gets what a login gives. Neither wants a token.
        var oc = newRq(coreRef.rqliteUrl)
        let onow = getTime().toUnix()
        if path == "/api/v1/oidc/callback":
          let cj = try: parseJson(getBody()) except JsonParsingError: nil
          if getMethod() != "POST" or cj == nil or not cj.isString("state") or not cj.isString("code"):
            problem(Http400, "invalid_request", "POST {\"state\": \"...\", \"code\": \"...\"} is required")
            return
          let vk = vaultKek()
          let res = oc.finishLogin(vk.kek, vk.ready, cj["state"].getStr, cj["code"].getStr, onow)
          case res.outcome
          of olOk:
            let ses = oc.sessionFor(res.user, onow)
            if not ses.ok:
              unauthorized("bad_credentials")
              return
            oc.record(onow, "user:" & res.user, "login", res.user, "ok", "oidc " & res.detail)
            jsonOk(Http200, %*{"token": ses.token, "user": res.user, "roles": ses.roles, "expires_at": ses.expiresAt, "password_change_required": false})
          of olBadState:
            oc.record(onow, "login", "login", "oidc", "failed", res.detail)
            problem(Http400, "bad_state", res.detail)
          of olRefused:
            oc.record(onow, "login", "login", "oidc", "failed", res.detail)
            problem(Http401, "oidc_refused", res.detail)
          of olNoAccount, olNameTaken:
            oc.record(onow, "user:" & res.user, "login", res.user, "no_account", res.detail)
            problem(Http403, "no_account", res.detail)
          of olNoRole:
            oc.record(onow, "user:" & res.user, "login", res.user, "no_role", res.detail)
            problem(Http403, "no_role", res.detail)
          of olUnavailable:
            oc.record(onow, "login", "login", "oidc", "directory_unavailable", res.detail)
            problem(Http503, "oidc_unavailable", res.detail)
          return
        let sparts = path["/api/v1/oidc/".len .. ^1].split('/')
        if getMethod() != "GET" or sparts.len != 3:
          problem(Http404, "not_found", "no such route")
          return
        let sorg = oc.organizationRow(sparts[0])
        let sprov = if sorg.id.len > 0 and sorg.state == "active": oc.providerById(sorg.id, sparts[1]) else: OidcProvider()
        if sprov.id.len == 0 or not sprov.enabled:
          problem(Http404, "not_found", "no such login")
          return
        let began = oc.beginLogin(sprov, onow)
        if not began.ok:
          problem(Http503, "oidc_unavailable", began.error)
          return
        jsonOk(Http200, %*{"url": began.url})
        return
      if path == "/api/v1/login/options":
        # D-87: what a login form offers before anyone is known: the organisations that have a directory (slug and name), so that a person picks theirs instead of typing `login@slug`.
        # Nothing else is told, and an organisation with no directory is not listed.
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var oc = newRq(coreRef.rqliteUrl)
        var os = newJArray()
        if authOn:
          let vals = oc.query(%*[["SELECT DISTINCT o.slug, o.name FROM organizations o JOIN ldap_servers s ON s.tenant_id = o.id WHERE o.state = 'active' AND s.enabled = 1 ORDER BY o.slug"]])["results"][0]{"values"}
          if vals != nil:
            for v in vals: os.add %*{"slug": v[0].getStr, "name": v[1].getStr}
        var oidcList = newJArray()
        if authOn:
          let pv = oc.query(%*[["SELECT o.slug, o.name, p.id, p.name FROM oidc_providers p JOIN organizations o ON o.id = p.tenant_id WHERE o.state = 'active' AND p.enabled = 1 ORDER BY o.slug, p.name"]])["results"][0]{"values"}
          if pv != nil:
            for v in pv: oidcList.add %*{"organization": v[0].getStr, "organization_name": v[1].getStr, "provider": v[2].getStr, "name": v[3].getStr}
        jsonOk(Http200, %*{"organizations": os, "oidc": oidcList})
        return
      if path == "/api/v1/login":
        # IAM-001: a user proves the password and gets a token with the rights of the user's roles (it needs no token itself)
        if getMethod() != "POST":
          problem(Http405, "method_not_allowed", "POST")
          return
        if not authOn:
          problem(Http409, "auth_off", "this API is open (neither CINIM_AUTH=on nor CINIM_ADMIN_TOKEN is set): there is nothing to log in to")
          return
        let lj = try: parseJson(getBody()) except JsonParsingError: nil
        if lj == nil or lj.kind != JObject or lj{"user"}.getStr("").len == 0 or lj{"password"}.getStr("").len == 0:
          problem(Http400, "invalid_request", "{\"user\": \"...\", \"password\": \"...\"} is required")
          return
        var lc = newRq(coreRef.rqliteUrl)
        let now = getTime().toUnix()
        var loginName = lj["user"].getStr
        # D-87: `organization` is the same as writing `@<organisation>` after the login (the login form of the UI has a list to choose it from)
        if lj.hasKey("organization") and lj["organization"].kind == JString and lj["organization"].getStr.len > 0:
          if '@' in loginName:
            problem(Http400, "invalid_request", "write the login without @organisation when the organization is given")
            return
          loginName = loginName & "@" & lj["organization"].getStr
        # too many wrong passwords for this name, or for all names together, and nobody is let in for a while (the audit is what is counted)
        let clientAddr = clientAddressOf(headerOfRaw(getRequest(), clientAddrHeaderName))           # D-97
        let addrNote = if clientAddr.len > 0: "addr=" & clientAddr else: ""
        let wait = lc.loginRetryAfter(loginName, now, clientAddr)
        if wait.blocked:
          lc.record(now, "login", "login", loginName, "throttled", "retry after " & $wait.seconds & " s " & addrNote)
          reply(Http429, $(%*{"type": "about:blank", "status": 429, "code": "too_many_attempts",
                              "detail": "too many wrong passwords; try again in " & $wait.seconds & " seconds"}),
                ["Content-Type: application/problem+json", "Retry-After: " & $wait.seconds])
          return
        # D-87: `<login>@<organisation>` is a person a directory of that organisation vouches for (a local user is never named with an @)
        let atAt = loginName.rfind('@')
        if atAt > 0:
          let vk = vaultKek()
          let ld = lc.ldapLogin(vk.kek, vk.ready, loginName[atAt + 1 .. ^1].toLowerAscii, loginName[0 ..< atAt], lj["password"].getStr, now)
          case ld.outcome
          of loNoDirectory: discard                                    # the organisation has no directory: the name is tried among the local users, which it will not be
          of loOk:
            let ldMfa = lc.checkSecondFactor(vaultKek().kek, ld.user, lj{"code"}.getStr(""), now)          # D-101
            if ldMfa == mcMissing:
              lc.record(now, "login", "login", ld.user, "mfa_required", addrNote)
              reply(Http401, $(%*{"type": "about:blank", "status": 401, "code": "mfa_required", "detail": "the directory accepts the password; send the code of the authenticator app (or a recovery code) as \"code\""}),
                    ["Content-Type: application/problem+json", "WWW-Authenticate: Bearer"])
              return
            if ldMfa == mcWrong:
              lc.record(now, "login", "login", ld.user, "failed", "second factor " & addrNote)
              unauthorized("bad_credentials")
              return
            let ses = lc.sessionFor(ld.user, now)
            if ses.ok:
              lc.record(now, "user:" & ld.user, "login", ld.user, "ok", "directory " & ld.detail)
              jsonOk(Http200, %*{"token": ses.token, "user": ld.user, "roles": ses.roles, "expires_at": ses.expiresAt, "password_change_required": false})
            else:
              unauthorized("bad_credentials")
            return
          of loNoRole:
            lc.record(now, "user:" & ld.user, "login", ld.user, "no_role", ld.detail)
            problem(Http403, "no_role", "the directory knows you, but no group of yours gives a role in the organisation " & loginName[atAt + 1 .. ^1])
            return
          of loUnavailable:
            lc.record(now, "login", "login", loginName, "directory_unavailable", ld.detail)
            problem(Http503, "directory_unavailable", "no directory of the organisation could be asked")
            return
          of loNoAccount:
            lc.record(now, "user:" & ld.user, "login", ld.user, "no_account", ld.detail)
            problem(Http403, "no_account", "the directory knows you, but the organisation " & loginName[atAt + 1 .. ^1] & " has no account for you: ask its administrator to make one")
            return
          of loBadCredentials, loNameTaken:
            lc.record(now, "login", "login", loginName, "failed", (if ld.detail.len > 0: ld.detail & " " else: "") & addrNote)
            unauthorized("bad_credentials")
            return
        let li = lc.login(loginName, lj["password"].getStr, now)
        if not li.ok:
          lc.record(now, "login", "login", loginName, "failed", addrNote)
          unauthorized("bad_credentials")
          return
        # D-101: the second factor, when the person has turned it on
        let mfaCode = lj{"code"}.getStr("")
        case lc.checkSecondFactor(vaultKek().kek, loginName, mfaCode, now)
        of mcNotNeeded, mcOk: discard
        of mcMissing:
          lc.record(now, "login", "login", loginName, "mfa_required", addrNote)
          reply(Http401, $(%*{"type": "about:blank", "status": 401, "code": "mfa_required", "detail": "the password is right; send the code of the authenticator app (or a recovery code) as \"code\""}),
                ["Content-Type: application/problem+json", "WWW-Authenticate: Bearer"])
          return
        of mcWrong:
          lc.record(now, "login", "login", loginName, "failed", "second factor " & addrNote)
          unauthorized("bad_credentials")
          return
        lc.record(now, "user:" & loginName, "login", loginName, "ok")
        jsonOk(Http200, %*{"token": li.token, "user": lj["user"].getStr, "roles": li.roles, "expires_at": li.expiresAt,
                           "password_change_required": li.mustChange})
        return
      # IAM-003: every route but /metrics and /healthz wants a token. An administrator may use all of them; a token of an organisation, only the runs of
      # that organisation (checked where the run is known)
      var who = Principal(ok: true, admin: true, name: "open API")
      if authOn:
        var ac = newRq(coreRef.rqliteUrl)
        who = authenticate(ac, adminToken, bearerOf(getRequest()), getTime().toUnix())
        if not who.ok:
          unauthorized(who.why)
          return
        who.need = needOf(getMethod(), path)          # D-84: what this request needs; `mayUseOrg` asks it again for the organisation a handler finds
        # D-101: where the shard requires a second factor, a person who has none may set it up and do nothing else
        if who.user.len > 0 and not who.limited and mfaRequired(mfaPolicy, who.admin) and not ac.mfaEnabled(who.user) and path != "/api/v1/me" and path != "/api/v1/me/can" and
           not path.startsWith("/api/v1/me/mfa") and not selfService(who.user, getMethod(), path):
          problem(Http403, "mfa_enrollment_required", "this shard requires two-step login: set it up first (POST /api/v1/me/mfa/totp:enroll, then :confirm)")
          return
        if who.mustChange and path != "/api/v1/me" and not selfService(who.user, getMethod(), path):
          # IAM-001: the password of this user has to be changed first (the administrator after the first login): that is the one thing allowed
          problem(Http403, "password_change_required", "change the password first: PUT " & passwordPath(who.user) & " {\"current_password\": \"...\", \"password\": \"...\"}")
          return
        if path == "/api/v1/token:rotate":
          # a token replaces itself: the first one has to (IAM-003), any other may at any time
          if getMethod() != "POST":
            problem(Http405, "method_not_allowed", "POST")
            return
          if who.operator:
            problem(Http409, "operator_token", "this token is set by the operator (CINIM_ADMIN_TOKEN); change it where it is set")
            return
          let made = ac.rotateApiToken(who.id, getTime().toUnix())
          if not made.ok:
            problem(Http404, "not_found", "no such token")
            return
          ac.record(getTime().toUnix(), actorOf(who), "token.rotate", who.id, "ok", "new " & made.id)
          jsonOk(Http200, %*{"id": made.id, "token": made.token, "replaced": who.id})
          return
        if not who.mayCall(getMethod(), path):
          if who.user.len > 0:
            # IAM-001, D-84: what the roles of the user give, at the shard and in organisations, is in permissions.nim; the permission is named so that the refusal can be read
            let wanted = if who.need.permission.len > 0: who.need.permission else: "(a route that is named for no role)"
            ac.record(getTime().toUnix(), actorOf(who), "access", getMethod() & " " & path, "denied", "needs " & wanted)
            problem(Http403, "forbidden", "the roles of " & who.user & " do not allow " & getMethod() & " " & path & ": it needs " & wanted)
          else:
            problem(Http403, "forbidden", "this token is for the runs of one organisation only")
          return
      if path == "/api/v1/me/mfa" or path.startsWith("/api/v1/me/mfa/"):
        # D-101: two-step login of the person. GET the state; POST /me/mfa/totp:enroll gives the secret and the address for an app; POST /me/mfa/totp:confirm {"code"} turns it on and gives the recovery codes
        # once; DELETE /me/mfa {"code"} turns it off (a code of the app, or a recovery code)
        if who.user.len == 0 or who.limited:
          problem(Http403, "forbidden", "two-step login is the setting of a person, made with the person\'s own login")
          return
        var mc = newRq(coreRef.rqliteUrl)
        let mnow = getTime().toUnix()
        let mk = vaultKek()
        let mj = if getBody().strip.len > 0: (try: parseJson(getBody()) except JsonParsingError: nil) else: newJObject()
        if path == "/api/v1/me/mfa" and getMethod() == "GET":
          jsonOk(Http200, %*{"enabled": mc.mfaEnabled(who.user), "required": mfaRequired(mfaPolicy, who.admin), "recovery_codes_left": mc.recoveryLeft(who.user)})
        elif path == "/api/v1/me/mfa/totp:enroll" and getMethod() == "POST":
          if not mk.ready:
            problem(Http503, "secrets_unavailable", "the secrets of the core are not available")
            return
          let e = mc.enrollTotp(mk.kek, who.user, mfaIssuer, mnow)
          if not e.ok:
            problem(Http409, "mfa_enroll", e.error)
            return
          mc.record(mnow, actorOf(who), "mfa.enroll", who.user, "ok")
          jsonOk(Http200, %*{"secret": e.secret, "uri": e.uri, "note": "add it to an authenticator app, then confirm with the code it shows"})
        elif path == "/api/v1/me/mfa/totp:confirm" and getMethod() == "POST":
          if mj == nil or not mj.isString("code"):
            problem(Http400, "invalid_request", "{\"code\": \"123456\"} is required")
            return
          if not mk.ready:
            problem(Http503, "secrets_unavailable", "the secrets of the core are not available")
            return
          let cf = mc.confirmTotp(mk.kek, who.user, mj["code"].getStr, mnow)
          if not cf.ok:
            problem(Http400, "mfa_confirm", cf.error)
            return
          mc.record(mnow, actorOf(who), "mfa.on", who.user, "ok")
          jsonOk(Http200, %*{"enabled": true, "recovery_codes": cf.recovery, "recovery_note": "shown only now; each is good once"})
        elif path == "/api/v1/me/mfa" and getMethod() == "DELETE":
          if mj == nil or not mj.isString("code"):
            problem(Http400, "invalid_request", "{\"code\": \"...\"} is required: a code of the app, or a recovery code")
            return
          if mc.mfaEnabled(who.user):
            let chk = mc.checkSecondFactor(mk.kek, who.user, mj["code"].getStr, mnow)
            if chk != mcOk:
              mc.record(mnow, actorOf(who), "mfa.off", who.user, "denied", "the code was not right")
              problem(Http403, "bad_code", "that code is not right")
              return
          mc.disableMfa(who.user)
          mc.record(mnow, actorOf(who), "mfa.off", who.user, "ok")
          jsonOk(Http200, %*{"enabled": false})
        else:
          problem(Http405, "method_not_allowed", "GET /me/mfa, POST /me/mfa/totp:enroll and :confirm, DELETE /me/mfa")
        return
      if path == "/api/v1/me/tokens" or path.startsWith("/api/v1/me/tokens/"):
        # D-99: a person\'s own tokens with a subset of their permissions. POST {name, permissions: [...], organization?, group?, expires_in?} (seconds, a day to a year, 30 days when left out) gives the token once;
        # GET lists them; DELETE /me/tokens/{id} revokes one. A token with a subset makes no token, and an administrator\'s token is the same as any other here (it is cut to what it names).
        if who.user.len == 0 or who.limited:
          problem(Http403, "forbidden", "tokens of a person are made with the person\'s own login, not with a token of the operator, of an organisation or with a subset")
          return
        var tc = newRq(coreRef.rqliteUrl)
        let tnow = getTime().toUnix()
        let tid = if path.len > "/api/v1/me/tokens/".len: path["/api/v1/me/tokens/".len .. ^1] else: ""
        if tid.len == 0 and getMethod() == "GET":
          jsonOk(Http200, %*{"tokens": tc.listOwnTokens(who.user)})
        elif tid.len == 0 and getMethod() == "POST":
          let tj = try: parseJson(getBody()) except JsonParsingError: nil
          if tj == nil or tj.kind != JObject or not tj.isString("name") or tj{"permissions"}.isNil or tj["permissions"].kind != JArray:
            problem(Http400, "invalid_request", "{\"name\": \"...\", \"permissions\": [\"run.read\", ...], \"organization\"?: \"slug\", \"group\"?: \"path\", \"expires_in\"?: seconds} is required")
            return
          var rs = TokenRestrict(organization: tj{"organization"}.getStr, group: normalPath(tj{"group"}.getStr))
          for x in tj["permissions"].elems:
            if x.kind != JString:
              problem(Http400, "invalid_request", "permissions are strings")
              return
            rs.permissions.add x.getStr
          if rs.group.len > 0 and rs.organization.len == 0:
            problem(Http400, "invalid_request", "a group needs its organisation")
            return
          let secs = if tj.hasKey("expires_in") and tj["expires_in"].kind == JInt: tj["expires_in"].getBiggestInt else: 30'i64 * 86400
          if secs < 86400 or secs > 365'i64 * 86400:
            problem(Http400, "invalid_request", "expires_in is between a day and a year (in seconds)")
            return
          let made = tc.createRestrictedToken(who.user, tj["name"].getStr, rs, tnow + secs, tnow)
          if made.error.len > 0:
            problem(Http400, "invalid_token", made.error)
            return
          tc.record(tnow, actorOf(who), "token.create", made.id, "ok", rs.permissions.join(","))
          jsonOk(Http201, %*{"id": made.id, "token": made.token, "permissions": rs.permissions, "expires_at": tnow + secs, "token_note": "shown only now"})
        elif tid.len > 0 and getMethod() == "DELETE":
          if not tc.revokeOwnToken(who.user, tid, tnow):
            problem(Http404, "not_found", "no such token of yours")
            return
          tc.record(tnow, actorOf(who), "token.revoke", tid, "ok")
          jsonOk(Http200, %*{"id": tid, "revoked": true})
        else:
          problem(Http405, "method_not_allowed", "GET and POST on /me/tokens, DELETE on /me/tokens/{id}")
        return
      if path == "/api/v1/me" or path == "/api/v1/me/can":
        # the caller, as the core sees them: roles, permissions, organisations (/me); and whether one call would be allowed, which permission it needs and which role gives it (/me/can)
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var mc = newRq(coreRef.rqliteUrl)
        if path == "/api/v1/me":
          var slugs: seq[string]
          if who.admin or (who.user.len > 0 and "org.read" in who.grants.shard):
            for o in mc.listOrganizationRows(): slugs.add o.slug
          jsonOk(Http200, mc.whoAmI(who, slugs))
          return
        var qMethod, qPath, qOrg, qProject = ""
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            case k
            of "method": qMethod = v.toUpperAscii
            of "path": qPath = v
            of "organization": qOrg = v
            of "project": qProject = normalPath(v)
        if qMethod notin ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"] or not qPath.startsWith("/api/v1/") or qPath.len > 400 or '?' in qPath:
          problem(Http400, "invalid_request", "?method=POST&path=/api/v1/runs/{id}:abort (a path of the API, without a query) is required; organization= and project= say where the thing is, for a route that does not name its organisation")
          return
        jsonOk(Http200, mc.explainCall(who, qMethod, qPath, qOrg, qProject))
        return
      if path == "/api/v1/users" or path.startsWith("/api/v1/users/"):
        # IAM-001: the users of the shard and their roles, for an administrator (the gate above lets no one else here)
        var uc = newRq(coreRef.rqliteUrl)
        let umeth = getMethod()
        if umeth == "GET" and path == "/api/v1/users":
          jsonOk(Http200, %*{"users": uc.listUsers()})
        elif umeth == "POST" and path == "/api/v1/users":
          # an administrator makes a user: {name, role, password}; the user can log in at once
          let nj = try: parseJson(getBody()) except JsonParsingError: nil
          if not (nj.isString("name") and nj.isString("role") and nj.isString("password")):
            problem(Http400, "invalid_request", "{\"name\": \"...\", \"role\": \"" & shardRoles.join("|") & "\", \"password\": \"...\"} is required")
            return
          let name = nj["name"].getStr
          if not validUserName(name):
            problem(Http400, "invalid_request", "a user name is lowercase letters, digits, - and _, starting with a letter, at most 32 characters")
            return
          # D-84: the role is a built-in one or one an administrator made; `organization` gives it in that organisation only (the user then sees only that)
          if not uc.roleExists(nj["role"].getStr):
            problem(Http400, "invalid_request", "no such role: " & nj["role"].getStr & " (GET /api/v1/roles)")
            return
          let orgOfUser = nj{"organization"}.getStr
          if orgOfUser.len > 0 and uc.organizationState(orgOfUser).len == 0:
            problem(Http404, "organization_not_found", "this shard has no organisation " & orgOfUser)
            return
          if orgOfUser.len == 0 and not allowedAtShard(nj["role"].getStr):
            # D-90: the shard is the super administrator's; the only users it has are administrators, every other person belongs to an organisation
            problem(Http400, "invalid_request", "a user of the shard is an administrator (role admin); any other user belongs to an organisation: give \"organization\"")
            return
          let lenBad = passwordProblem(nj["password"].getStr)
          if lenBad.len > 0:
            problem(Http400, "invalid_password", lenBad)
            return
          let nv = checkPassword(pwnedCfg, nj["password"].getStr)
          if nv.problem.len > 0:
            problem(Http400, nv.code, nv.problem)
            return
          let scopeOfUser = if orgOfUser.len > 0: "org:" & orgOfUser else: shardScope
          if not uc.createUser(name, nj["role"].getStr, nj["password"].getStr, getTime().toUnix(), scopeOfUser):
            problem(Http409, "user_exists", "there is a user " & name & " already")
            return
          uc.record(getTime().toUnix(), actorOf(who), "user.create", name, "ok", "role " & nj["role"].getStr & " in " & scopeOfUser)
          jsonOk(Http201, %*{"name": name, "role": nj["role"].getStr, "scope": scopeOfUser, "breach_check": nv.breachCheck})
        elif umeth == "DELETE" and path.startsWith("/api/v1/users/") and path.count('/') == 4:
          let name = path["/api/v1/users/".len .. ^1]
          if name == roleAdmin:
            problem(Http403, "forbidden", "the user admin cannot be deleted")
            return
          if not uc.deleteUser(name, getTime().toUnix()):
            problem(Http404, "not_found", "no such user")
            return
          uc.record(getTime().toUnix(), actorOf(who), "user.delete", name, "ok")
          jsonOk(Http200, %*{"name": name, "deleted": true})
        elif umeth == "PUT" and userOfPasswordPath(path).len > 0:
          # a user changes their own password (the gate lets a user of any role in for exactly this), an administrator anyone's. A user changing their own
          # also proves the current one, so that a stolen token does not take the account over.
          let name = userOfPasswordPath(path)
          if uc.userSourceOf(name).len > 0:
            problem(Http409, "directory_user", "this account has no password of its own: its directory knows it")
            return
          let pj = try: parseJson(getBody()) except JsonParsingError: nil
          if not pj.isString("password"):
            problem(Http400, "invalid_request", "{\"password\": \"...\"} is required" & (if who.user == name: ", with \"current_password\"" else: ""))
            return
          let bad = passwordProblem(pj["password"].getStr)
          if bad.len > 0:
            problem(Http400, "invalid_password", bad)
            return
          if who.user == name and not uc.passwordIs(name, pj{"current_password"}.getStr("")):
            uc.record(getTime().toUnix(), actorOf(who), "password.change", name, "failed", "the current password was wrong")
            problem(Http403, "wrong_password", "the current password is not right")
            return
          if who.user == name and pj["password"].getStr == pj{"current_password"}.getStr(""):
            problem(Http400, "invalid_password", "the new password must differ from the current one")
            return
          # too simple (local rules) or known from breaches (Pwned Passwords; if it does not answer, the local rules decided and the answer says so)
          let verdict = checkPassword(pwnedCfg, pj["password"].getStr)
          if verdict.problem.len > 0:
            problem(Http400, verdict.code, verdict.problem)
            return
          if verdict.breachCheck == "local":
            stderr.writeLine "core: the breach service did not answer; the password of " & name & " was checked by the local rules only"
          let done = uc.changePassword(name, pj["password"].getStr, getTime().toUnix(), keepToken = who.id)
          if not done.ok:
            problem(Http404, "not_found", "no such user")
            return
          uc.record(getTime().toUnix(), actorOf(who), "password.change", name, "ok", "sessions revoked " & $done.sessionsRevoked)
          jsonOk(Http200, %*{"user": name, "changed": true, "sessions_revoked": done.sessionsRevoked, "breach_check": verdict.breachCheck})
        else:
          problem(Http404, "not_found", "no such route")
        return
      if path == "/api/v1/audit/export":
        # D-97: the events as lines of JSON, the oldest first, after the id given: for a system that fetches (?after=<id>&limit=<n>, at most 500); the last id is in X-Audit-Last-Id
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var after = 0'i64
        var lim = maxBatch
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            try:
              if k == "after": after = parseBiggestInt(v)
              if k == "limit": lim = parseInt(v)
            except ValueError:
              problem(Http400, "invalid_request", k & " must be a whole number")
              return
        var ec = newRq(coreRef.rqliteUrl)
        let evs = ec.eventsAfter(after, lim)
        reply(Http200, ndjson(evs), ["Content-Type: application/x-ndjson", "X-Audit-Last-Id: " & (if evs.len > 0: $evs[^1].id else: $after)])
        return
      if path == "/api/v1/audit/sinks" or path.startsWith("/api/v1/audit/sinks/"):
        # D-97: where the audit log is sent. GET the sinks (audit.read); PUT /sinks/{name} {"url": ..., "token_env"?, "enabled"?, "from_start"?} and DELETE /sinks/{name} (audit.export)
        var sc = newRq(coreRef.rqliteUrl)
        let sname = if path.len > "/api/v1/audit/sinks/".len: path["/api/v1/audit/sinks/".len .. ^1] else: ""
        if sname.len == 0:
          if getMethod() != "GET":
            problem(Http405, "method_not_allowed", "GET")
            return
          var arr = newJArray()
          for s in sc.listSinks(): arr.add s.view
          jsonOk(Http200, %*{"sinks": arr})
        elif getMethod() == "PUT":
          let sj = try: parseJson(getBody()) except JsonParsingError: nil
          let ps = parseSink(sname, sj)
          if ps.error.len > 0:
            problem(Http400, "invalid_request", ps.error)
            return
          sc.putSink(ps.sink, sj{"from_start"}.getBool(false))
          sc.record(getTime().toUnix(), actorOf(who), "audit.sink", sname, "ok", ps.sink.url)
          jsonOk(Http200, %*{"name": sname, "url": ps.sink.url, "enabled": ps.sink.enabled})
        elif getMethod() == "DELETE":
          if not sc.deleteSink(sname):
            problem(Http404, "not_found", "no such sink")
            return
          sc.record(getTime().toUnix(), actorOf(who), "audit.sink.delete", sname, "ok")
          jsonOk(Http200, %*{"name": sname, "deleted": true})
        else:
          problem(Http405, "method_not_allowed", "GET, PUT or DELETE")
        return
      if path == "/api/v1/audit":
        # IAM-001, D-52: who did what to whom (administrator): ?limit=100 (at most 1000), ?actor=, ?action=, ?target=; the newest first
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var limit, actor, action, target = ""
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            case k
            of "limit": limit = v
            of "actor": actor = v
            of "action": action = v
            of "target": target = v
            else: discard
        var ac2 = newRq(coreRef.rqliteUrl)
        let lim = try: parseInt(if limit.len > 0: limit else: "100") except ValueError: 100
        jsonOk(Http200, %*{"events": ac2.list(lim, actor, action, target)})
        return
      if path == "/api/v1/permissions":
        # D-84: what a role can be made of: every permission, at which level it may be given, and what it allows
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var perms = newJArray()
        for p in catalogue: perms.add %*{"name": p.name, "level": (if p.level == lvShard: "shard" else: "organization"), "description": p.text}
        jsonOk(Http200, %*{"permissions": perms})
        return
      if path == "/api/v1/roles" or path.startsWith("/api/v1/roles/"):
        # IAM-001, D-84: the roles (GET: whoever may see who has which role; PUT and DELETE: an administrator makes roles of their own out of permissions)
        var rc = newRq(coreRef.rqliteUrl)
        let rmeth = getMethod()
        if path == "/api/v1/roles":
          if rmeth != "GET":
            problem(Http405, "method_not_allowed", "GET")
            return
          jsonOk(Http200, %*{"roles": rc.listRoles()})
          return
        let roleName = path["/api/v1/roles/".len .. ^1]
        if rmeth == "PUT":
          let rj = try: parseJson(getBody()) except JsonParsingError: nil
          if rj == nil or rj.kind != JObject or rj{"permissions"}.isNil or rj{"permissions"}.kind != JArray:
            problem(Http400, "invalid_request", "{\"description\": \"...\", \"permissions\": [\"run.start\", ...]} is required (GET /api/v1/permissions)")
            return
          var wanted: seq[string]
          for x in rj["permissions"].elems:
            if x.kind != JString:
              problem(Http400, "invalid_request", "permissions are strings")
              return
            wanted.add x.getStr
          let existed = rc.roleExists(roleName)
          let bad = rc.putRole(roleName, rj{"description"}.getStr, wanted)
          if bad.len > 0:
            problem(Http400, "invalid_role", bad)
            return
          rc.record(getTime().toUnix(), actorOf(who), "role.put", roleName, "ok", wanted.join(","))
          jsonOk(if existed: Http200 else: Http201, %*{"name": roleName, "permissions": wanted})
        elif rmeth == "DELETE":
          case rc.deleteRole(roleName)
          of rdDeleted:
            rc.record(getTime().toUnix(), actorOf(who), "role.delete", roleName, "ok")
            jsonOk(Http200, %*{"name": roleName, "deleted": true})
          of rdNotFound: problem(Http404, "not_found", "no such role")
          of rdBuiltin: problem(Http409, "builtin_role", "admin, rw, dev and ro are made in code and cannot be deleted")
          of rdInUse: problem(Http409, "role_in_use", "this role is given to a user; take it away first")
        else:
          problem(Http405, "method_not_allowed", "PUT, DELETE")
        return
      if path == "/api/v1/tokens" or path.startsWith("/api/v1/tokens/"):
        var c = newRq(coreRef.rqliteUrl)
        let tmeth = getMethod()
        if tmeth == "POST" and path == "/api/v1/tokens":
          let j = try: parseJson(getBody()) except JsonParsingError: nil
          if j == nil or j.kind != JObject or not j.hasKey("scope") or j["scope"].kind != JString or not validScope(j["scope"].getStr):
            problem(Http400, "invalid_request", "scope is required: `admin` or `org:<slug>`")
            return
          let ttl = j{"ttl_seconds"}.getBiggestInt(0)
          if j.hasKey("ttl_seconds") and ttl < 0:
            problem(Http400, "invalid_request", "ttl_seconds must be a positive number of seconds, or left out for a token that does not expire")
            return
          let now = getTime().toUnix()
          let name = j{"name"}.getStr("")
          let made = c.createApiToken(name, j["scope"].getStr, (if ttl > 0: now + ttl else: 0), now)
          # the token is shown here and never again: only its hash is kept
          c.record(now, actorOf(who), "token.create", made.id, "ok", "scope " & j["scope"].getStr)
          jsonOk(Http201, %*{"id": made.id, "token": made.token, "name": name, "scope": j["scope"].getStr, "expires_at": (if ttl > 0: now + ttl else: 0)})
        elif tmeth == "GET" and path == "/api/v1/tokens":
          jsonOk(Http200, %*{"tokens": c.listApiTokens()})
        elif tmeth == "DELETE" and path.startsWith("/api/v1/tokens/"):
          let id = path["/api/v1/tokens/".len .. ^1]
          if not c.revokeApiToken(id, getTime().toUnix()):
            problem(Http404, "not_found", "no such token, or it is revoked already")
            return
          c.record(getTime().toUnix(), actorOf(who), "token.revoke", id, "ok")
          jsonOk(Http200, %*{"id": id, "revoked": true})
        else:
          problem(Http404, "not_found", "no such route")
        return
      if path == "/api/v1/components":
        jsonOk(Http200, componentsJson())
        return
      if path == "/api/v1/launch-gate":
        # RUN-015: the API gives the reason new steps are not starting
        let g = currentGate()
        jsonOk(Http200, %*{"open": g.isOpen, "state": $g.state, "reason": g.reason, "since": g.since})
        return
      if path == "/api/v1/profile":
        # D-27, D-29: the execution profile's settings. PUT takes any subset; missing fields keep their value.
        # `?organization=<slug>` addresses the profile of an organisation (SHD-007), otherwise it is the shard's default one.
        var profileId = ""
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            if k == "organization":
              var oc = newRq(coreRef.rqliteUrl)
              let org = oc.organizationRow(v)
              if org.id.len == 0:
                problem(Http404, "organization_not_found", "this shard has no organisation " & v)
                return
              profileId = oc.ensureOrganizationProfile(org.id, namespaceName(orgPrefix, orgShard, v))
        if getMethod() == "GET":
          jsonOk(Http200, coreRef.getProfileSettings(profileId))
        elif getMethod() == "PUT":
          let j = try: parseJson(getBody()) except JsonParsingError: nil
          if j == nil or j.kind != JObject:
            problem(Http400, "invalid_request", "a JSON object with any of infra_retries, log_max_bytes, log_spool_bytes, log_hold_timeout, liveness_timeout, pod_limit, job_pod_limit_percent, runs_per_conductor, conductor_min is required")
            return
          let cur = coreRef.getProfileSettings(profileId)
          var s = ProfileSettings(infraRetries: cur["infra_retries"].getInt, logMaxBytes: cur["log_max_bytes"].getBiggestInt,
                                  livenessTimeout: cur["liveness_timeout"].getInt, logSpoolBytes: cur["log_spool_bytes"].getBiggestInt,
                                  logHoldTimeout: cur["log_hold_timeout"].getInt, podLimit: cur["pod_limit"].getInt,
                                  jobPodLimitPercent: cur["job_pod_limit_percent"].getInt, runsPerConductor: cur["runs_per_conductor"].getInt,
                                  conductorMin: cur["conductor_min"].getInt, artifactQuotaBytes: cur["artifact_quota_bytes"].getBiggestInt,
                                  artifactRetentionDays: cur["artifact_retention_days"].getInt, cacheQuotaBytes: cur["cache_quota_bytes"].getBiggestInt,
                                  cacheRetentionDays: cur["cache_retention_days"].getInt, auditVariables: cur["audit_variables"].getStr)
          for k in ["artifact_quota_bytes", "artifact_retention_days", "cache_quota_bytes", "cache_retention_days", "infra_retries", "log_max_bytes", "liveness_timeout", "log_spool_bytes", "log_hold_timeout", "pod_limit", "job_pod_limit_percent", "runs_per_conductor", "conductor_min"]:
            if j.hasKey(k) and j[k].kind != JInt:
              problem(Http400, "invalid_request", k & " must be an integer")
              return
          if j.hasKey("infra_retries"): s.infraRetries = j["infra_retries"].getInt
          if j.hasKey("log_max_bytes"): s.logMaxBytes = j["log_max_bytes"].getBiggestInt
          if j.hasKey("liveness_timeout"): s.livenessTimeout = j["liveness_timeout"].getInt
          if j.hasKey("log_spool_bytes"): s.logSpoolBytes = j["log_spool_bytes"].getBiggestInt
          if j.hasKey("log_hold_timeout"): s.logHoldTimeout = j["log_hold_timeout"].getInt
          if j.hasKey("pod_limit"): s.podLimit = j["pod_limit"].getInt
          if j.hasKey("job_pod_limit_percent"): s.jobPodLimitPercent = j["job_pod_limit_percent"].getInt
          if j.hasKey("runs_per_conductor"): s.runsPerConductor = j["runs_per_conductor"].getInt
          if j.hasKey("conductor_min"): s.conductorMin = j["conductor_min"].getInt
          if j.hasKey("artifact_quota_bytes"): s.artifactQuotaBytes = j["artifact_quota_bytes"].getBiggestInt
          if j.hasKey("artifact_retention_days"): s.artifactRetentionDays = j["artifact_retention_days"].getInt
          if j.hasKey("cache_quota_bytes"): s.cacheQuotaBytes = j["cache_quota_bytes"].getBiggestInt
          if j.hasKey("cache_retention_days"): s.cacheRetentionDays = j["cache_retention_days"].getInt
          if j.hasKey("audit_variables"):
            if j["audit_variables"].kind != JString:
              problem(Http400, "invalid_request", "audit_variables must be off, digest or full")
              return
            s.auditVariables = j["audit_variables"].getStr
          let bad = validate(s)
          if bad.len > 0:
            problem(Http400, "invalid_request", bad)
            return
          coreRef.setProfileSettings(s, profileId)
          jsonOk(Http200, coreRef.getProfileSettings(profileId))
        else:
          problem(Http405, "method_not_allowed", "GET or PUT")
        return
      if path == "/api/v1/organizations:check":
        # SHD-007: what the UI asks while a slug is typed - the rules, and how many characters the namespace name still allows
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var slug = ""
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            if k == "slug": slug = v
        let reason = checkSlug(slug, orgPrefix, orgShard)
        jsonOk(Http200, %*{"ok": reason.len == 0, "reason": reason, "chars_left": charsLeft(orgPrefix, orgShard, slug),
                           "namespace": namespaceName(orgPrefix, orgShard, slug), "max_slug_length": maxSlugLen(orgPrefix, orgShard)})
        return
      if path == "/api/v1/alerts":
        # what an operator should look at, in one list (the UI shows it as alerts): Pods kept because they could not be read, what the
        # reconciliation found (SHD-008) and a slug held by two cores (SHD-006)
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var all = newJArray()
        for a in keptAlerts(): all.add a
        let rec = lastPassJson()
        if rec.len > 0:
          for a in parseJson(rec){"alerts"}: all.add a
        let cfg = currentConfig()
        var c = newRq(coreRef.rqliteUrl)
        var slugs: seq[string]
        for o in c.listOrganizationRows(): slugs.add o.slug
        for a in alerts(currentView().items, cfg.coreId, slugs):
          all.add %*{"code": a.code, "slug": a.slug, "other_core": a.otherCore}
        jsonOk(Http200, %*{"alerts": all})
        return
      if path == "/api/v1/organizations:reconcile":
        # SHD-008: the result of the last pass of the reconciliation (what it made again, the alerts, what the retention deleted); POST runs a pass now
        let e = reconcileEnv(coreRef)
        if getMethod() == "POST":
          if not provisionOn:
            problem(Http409, "not_in_a_cluster", "the core does not run in a cluster, or CINIM_PROVISION is off")
            return
          var body = runPass(e, kube).toJson
          body["interval"] = %e.interval
          body["retention"] = %e.retention
          jsonOk(Http200, body)
        elif getMethod() == "GET":
          let last = lastPassJson()
          var body = if last.len > 0: parseJson(last) else: %*{"at": 0, "organizations": [], "alerts": [], "deleted": [], "error": "no pass has run yet"}
          body["interval"] = %e.interval
          body["retention"] = %e.retention
          jsonOk(Http200, body)
        else:
          problem(Http405, "method_not_allowed", "GET or POST")
        return
      if path == "/api/v1/organizations":
        var c = newRq(coreRef.rqliteUrl)
        let cfg = currentConfig()
        if getMethod() == "GET":
          var arr = newJArray()
          let visible = who.visibleOrgs("org.read")
          for o in c.listOrganizationRows():
            if not visible.all and o.slug notin visible.slugs and (who.user.len == 0 or o.slug notin who.grants.orgsTouched): continue
            arr.add %*{"id": o.id, "slug": o.slug, "name": o.name, "state": o.state, "url": orgUrl(cfg.publicBase, o.slug),
                       "namespace": namespaceName(orgPrefix, orgShard, o.slug)}
          jsonOk(Http200, %*{"organizations": arr})
        elif getMethod() == "POST":
          # SHD-007 steps (1) and (6): the rules, the router's list, the record. The namespace, the controller and the Ingress are not
          # created by the core yet.
          let j = try: parseJson(getBody()) except JsonParsingError: nil
          if j == nil or j.kind != JObject or not j.hasKey("slug") or j["slug"].kind != JString:
            problem(Http400, "invalid_request", "a JSON object with a string `slug` (and optionally `name`) is required")
            return
          let slug = j["slug"].getStr
          # SHD-009: the simple mode of a small organisation, `"network": {"egress": "open", "ingress": "open"}`; what is left out is the shard's default
          var netEgress, netIngress = ""
          if j.hasKey("network"):
            let nw = j["network"]
            if nw.kind != JObject:
              problem(Http400, "invalid_request", "network must be an object with `egress` (open, restricted) and `ingress` (open, closed)")
              return
            netEgress = nw{"egress"}.getStr
            netIngress = nw{"ingress"}.getStr
            if netEgress notin ["", "open", "restricted"] or netIngress notin ["", "open", "closed"]:
              problem(Http400, "invalid_request", "network.egress is open or restricted, network.ingress is open or closed")
              return
          let reason = checkSlug(slug, orgPrefix, orgShard)
          if reason.len > 0:
            problem(Http400, "invalid_slug", reason)
            return
          if c.organizationState(slug).len > 0:
            problem(Http409, "slug_exists", "this shard already has an organisation with that slug")
            return
          let view = currentView()
          let other = conflictWith(view.items, cfg.coreId, slug)
          if other.len > 0:
            problem(Http409, "slug_taken", "the slug is already held by the core " & other & " (the list of the router)")
            return
          var provisioned = newJObject()
          if provisionOn:
            # the namespace and what the controller needs; the controller itself is a Pod that the core makes in its next pass, with the one-time token of the identity
            # (IAM-003, orgreconcile.nim), which is asked for right after the organisation is recorded
            let pc = provisionConfig(cfg, netEgress, netIngress)
            let r = provision(kube, pc, slug, loadCurve(coreRef.certs))
            if not r.ok:
              # what was made stays; asking again makes the rest (every create is idempotent)
              reply(Http502, $(%*{"type": "about:blank", "status": 502, "code": "provision_failed", "step": r.failedStep,
                                  "detail": r.error, "done": stepsJson(r)}), ["Content-Type: application/problem+json"])
              return
            provisioned = %*{"steps": stepsJson(r), "skipped": r.skipped}
          let netNow = provisionConfig(cfg, netEgress, netIngress)
          let egressNow = netNow.egressOpen
          let ingressNow = netNow.ingressOpen
          let id = try: c.addOrganization(slug, j{"name"}.getStr, netEgress, netIngress)
                   except RqError:
                     problem(Http409, "slug_exists", "this shard already has an organisation with that slug")
                     return
          if provisionOn: requestPass()                                                      # the supervision makes the controller's Pod
          jsonOk(Http201, %*{"id": id, "slug": slug, "name": j{"name"}.getStr, "namespace": namespaceName(orgPrefix, orgShard, slug),
                             "url": orgUrl(cfg.publicBase, slug), "provisioned": provisionOn,
                             "network": {"egress": (if egressNow: "open" else: "restricted"), "ingress": (if ingressNow: "open" else: "closed")}, "kubernetes": provisioned,
                             "checked_against_router": view.configured and view.fetchedAt > 0})
        else:
          problem(Http405, "method_not_allowed", "GET or POST")
        return
      if path == "/api/v1/stores":
        # D-60: the stores are the storage module's (docs/storage-module.md); the operator makes and changes them there, with the module's admin token. The core shows what the module has,
        # so that an administrator sees which names an organisation may choose.
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET; the stores are made and changed in the storage module (docs/storage-module.md)")
          return
        let known = moduleStores()
        if not known.ok:
          problem(if known.error == "not_configured": Http409 else: Http502, if known.error == "not_configured": "storage_not_configured" else: "storage_unreachable",
                  if known.error == "not_configured": "this shard has no storage module (CINIM_STORAGE_URL)" else: known.error)
          return
        var items = newJArray()
        for e in known.stores: items.add %*{"name": e.name, "kind": e.kind, "default": e.isDefault}
        jsonOk(Http200, %*{"stores": items, "default": known.defaultName, "purposes": purposes})
        return
      if path == "/api/v1/variables" or path.startsWith("/api/v1/variables/"):
        # VAR-001, D-54: the variables of the shard, the lowest level: every step of every organisation gets them. An administrator writes them (rbac.nim)
        var sc = newRq(coreRef.rqliteUrl)
        sc.serveVariables(vsShard, "", path["/api/v1/variables".len .. ^1].strip(chars = {'/'}), %*{"level": "shard"},
                          VarAudit(level: "shard", master: coreSecret(coreRef.certs), who: who))
        return
      if path.startsWith("/api/v1/organizations/") and path.endsWith("/hold") and not ("/groups" in path):
        # DAT-006: a legal hold on the whole organisation
        let slugO = path["/api/v1/organizations/".len ..< path.len - "/hold".len]
        var oq = newRq(coreRef.rqliteUrl)
        let orgO = oq.organizationRow(slugO)
        if slugO.len == 0 or "/" in slugO or orgO.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugO)
          return
        oq.serveScopeHold(orgO.id, slugO, "", "", who)
        return
      if path.startsWith("/api/v1/organizations/") and path.endsWith("/storage"):
        # D-59: which store an organisation uses for each purpose (artifacts, caches, held_logs, audit); a purpose with none uses the default store of the shard.
        # GET shows the choice and the stores to choose from; PUT {"artifacts": "<store>", "caches": ""} changes the purposes it names ("" is the default again).
        let slugS = path["/api/v1/organizations/".len ..< path.len - "/storage".len]
        var sc = newRq(coreRef.rqliteUrl)
        let orgS = sc.organizationRow(slugS)
        if slugS.len == 0 or "/" in slugS or orgS.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugS)
          return
        proc choiceJson(): JsonNode =
          var chosen = newJObject()
          for p in purposes: chosen[p] = %""
          for (purpose, store) in sc.orgStorage(orgS.id): chosen[purpose] = %store
          var effective = newJObject()
          for p in purposes: effective[p] = %sc.storeFor(orgS.id, p)
          var names = newJArray()
          let known = moduleStores()
          for e in known.stores: names.add %e.name
          %*{"organization": slugS, "storage": chosen, "effective": effective, "default": known.defaultName, "stores": names}
        if getMethod() == "GET":
          jsonOk(Http200, choiceJson())
        elif getMethod() == "PUT":
          let sj = try: parseJson(getBody()) except JsonParsingError: nil
          if sj == nil or sj.kind != JObject or sj.len == 0:
            problem(Http400, "invalid_request", "the body is {\"artifacts\": \"<store>\", \"caches\": \"<store>\", ...}; an empty name is the default store")
            return
          for k, v in sj:
            if v.kind != JString:
              problem(Http400, "invalid_request", k & " is the name of a store, as text")
              return
            let why = sc.setOrgStorage(orgS.id, k, v.getStr, actorOf(who), getTime().toUnix())
            if why.len > 0:
              problem(Http400, "invalid_request", why)
              return
            sc.record(getTime().toUnix(), actorOf(who), "storage.select", slugS, "ok", k & " -> " & (if v.getStr.len > 0: v.getStr else: "(default)"))
          jsonOk(Http200, choiceJson())
        else:
          problem(Http405, "method_not_allowed", "GET or PUT")
        return
      if path.startsWith("/api/v1/organizations/") and path.endsWith("/caches"):
        # DAT-004: the caches of an organisation (docs/cache.md): GET lists them with what each limit holds, ?group=<path> narrows to a group and the groups below it;
        # DELETE takes entries of exactly one scope out: ?group=<path> (none: the organisation's own) with ?key=<key> for one, or ?all=true for all of them
        let slugC = path["/api/v1/organizations/".len ..< path.len - "/caches".len]
        var cc = newRq(coreRef.rqliteUrl)
        let orgC = cc.organizationRow(slugC)
        if slugC.len == 0 or "/" in slugC or orgC.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugC)
          return
        var groupQ, keyQ = ""
        var allQ = false
        var limitQ = 500
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            case k
            of "group": groupQ = normalPath(v)
            of "key": keyQ = v
            of "all": allQ = v == "true"
            of "limit": limitQ = (try: parseInt(v) except ValueError: 500)
            else: discard
        var groupId = ""
        if groupQ.len > 0:
          let g = cc.groupIdOf(orgC.id, groupQ)
          if not g.found:
            problem(Http404, "group_not_found", "the organisation " & slugC & " has no group " & groupQ)
            return
          groupId = g.id
        if getMethod() == "GET":
          var items = newJArray()
          for r in cc.listCaches(orgC.id, groupQ, limitQ):
            items.add %*{"group": r.groupPath, "key": r.key, "state": r.state, "size": r.size, "sha256": r.sha256, "created_at": r.createdAt, "last_used_at": r.lastUsedAt}
          var pools = newJArray()
          for p in cc.poolUsage(orgC.id, cacheQuotaFromEnv()):
            var pj = %*{"level": p.name, "quota": p.quota, "bytes": p.bytes}
            if p.groupPath.len > 0: pj["group"] = %p.groupPath
            pools.add pj
          jsonOk(Http200, %*{"organization": slugC, "pools": pools, "caches": items})
        elif getMethod() == "DELETE":
          if keyQ.len == 0 and not allQ:
            problem(Http400, "invalid_request", "name the entry with ?key=<key>, or every entry of the scope with ?all=true (and ?group=<path> for a group's; none is the organisation's own)")
            return
          let gone = cc.deleteEntries(newStoreSet(), orgC.id, groupId, keyQ)
          if gone.deleted > 0: cc.record(getTime().toUnix(), actorOf(who), "cache.delete", slugC & (if groupQ.len > 0: "/" & groupQ else: ""), "ok", (if keyQ.len > 0: keyQ else: "all") & ": " & $gone.deleted)
          jsonOk(Http200, %*{"organization": slugC, "group": groupQ, "deleted": gone.deleted, "failed": gone.failed})
        else:
          problem(Http405, "method_not_allowed", "GET or DELETE")
        return
      if path.startsWith("/api/v1/organizations/") and path.endsWith("/holds"):
        # DAT-006: the runs of an organisation under a legal hold
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        let slugH = path["/api/v1/organizations/".len ..< path.len - "/holds".len]
        var hq = newRq(coreRef.rqliteUrl)
        let orgHq = hq.organizationRow(slugH)
        if orgHq.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugH)
          return
        var items = newJArray()
        for h in hq.listHolds(orgHq.id): items.add h.view
        var scopes = newJArray()
        for h in hq.listScopeHolds(orgHq.id): scopes.add h.view
        jsonOk(Http200, %*{"organization": slugH, "holds": items, "scopes": scopes})
        return
      if path.startsWith("/api/v1/organizations/") and "/teams" in path:
        # D-91: the teams of an organisation. The gate has checked access.read / access.write in the organisation.
        #   GET /organizations/{slug}/teams
        #   PUT|DELETE /organizations/{slug}/teams/{name}      PUT {"description", "ldap": {"group_dn", "directory"?} | null}
        #   PUT|DELETE /organizations/{slug}/teams/{name}/members/{user}     (the roles of a team: .../members/team:{name} of the organisation or of a group)
        let partsT = path["/api/v1/organizations/".len .. ^1].split('/')
        if partsT.len < 2 or partsT[1] != "teams":
          problem(Http404, "not_found", "no such route")
          return
        let slugT = partsT[0]
        var tc = newRq(coreRef.rqliteUrl)
        let orgT = tc.organizationRow(slugT)
        if orgT.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugT)
          return
        let tmeth = getMethod()
        let nowT = getTime().toUnix()
        if partsT.len == 2 and tmeth == "GET":
          jsonOk(Http200, %*{"organization": slugT, "teams": tc.listTeams(orgT.id, slugT)})
        elif partsT.len == 3 and tmeth == "PUT":
          let tj = try: (if getBody().strip.len == 0: newJObject() else: parseJson(getBody())) except JsonParsingError: nil
          let done = tc.putTeam(orgT.id, partsT[2], tj, nowT)
          if done.error.len > 0:
            problem(HttpCode(done.status), "invalid_team", done.error)
            return
          tc.record(nowT, actorOf(who), "team.put", slugT & "/" & partsT[2], "ok")
          jsonOk(if done.created: Http201 else: Http200, %*{"organization": slugT, "team": partsT[2]})
        elif partsT.len == 3 and tmeth == "DELETE":
          if not tc.deleteTeam(orgT.id, slugT, partsT[2]):
            problem(Http404, "not_found", "no such team")
            return
          tc.record(nowT, actorOf(who), "team.delete", slugT & "/" & partsT[2], "ok")
          jsonOk(Http200, %*{"organization": slugT, "team": partsT[2], "deleted": true})
        elif partsT.len == 5 and partsT[3] == "members" and tmeth == "PUT":
          let added = tc.addTeamMember(orgT.id, partsT[2], partsT[4])
          if added.error.len > 0:
            problem(HttpCode(added.status), "invalid_member", added.error)
            return
          tc.record(nowT, actorOf(who), "team.member", slugT & "/" & partsT[2] & " + " & partsT[4], "ok")
          jsonOk(Http200, %*{"organization": slugT, "team": partsT[2], "user": partsT[4], "member": true})
        elif partsT.len == 5 and partsT[3] == "members" and tmeth == "DELETE":
          let gone = tc.removeTeamMember(orgT.id, partsT[2], partsT[4])
          if gone.error.len > 0:
            problem((if gone.found: Http409 else: Http404), (if gone.found: "directory_member" else: "not_found"), gone.error)
            return
          if not gone.found:
            problem(Http404, "not_found", "this person is not a member of the team")
            return
          tc.record(nowT, actorOf(who), "team.member_remove", slugT & "/" & partsT[2] & " - " & partsT[4], "ok")
          jsonOk(Http200, %*{"organization": slugT, "team": partsT[2], "user": partsT[4], "member": false})
        else:
          problem(Http404, "not_found", "no such route")
        return
      if path.startsWith("/api/v1/organizations/") and "/ldap" in path:
        # D-87: the directories of an organisation and the map of their groups to roles. The gate has checked the permission for this organisation (ldap.read; ldap.map for the map and for a
        # sync; ldap.write, the shard's, for adding, changing, checking and removing a directory: the core connects to the address that is given).
        #   GET /organizations/{slug}/ldap
        #   PUT|DELETE /organizations/{slug}/ldap/servers/{name}     POST .../servers/{name}:check {"user": "ann"} (nothing is changed)     POST .../servers/{name}:sync
        #   POST /organizations/{slug}/ldap/mappings {"group_dn", "role", "directory"?}     DELETE /organizations/{slug}/ldap/mappings/{id}
        let afterOrgL = path["/api/v1/organizations/".len .. ^1]
        let partsL = afterOrgL.split('/')
        if partsL.len < 2 or partsL[1] != "ldap":
          problem(Http404, "not_found", "no such route")
          return
        let slugL = partsL[0]
        var lc = newRq(coreRef.rqliteUrl)
        let orgL = lc.organizationRow(slugL)
        if orgL.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugL)
          return
        let lmeth = getMethod()
        let vkL = vaultKek()
        let nowL = getTime().toUnix()
        if partsL.len == 2:
          if lmeth != "GET":
            problem(Http405, "method_not_allowed", "GET")
            return
          var ds = newJArray()
          for s in lc.serversOf(orgL.id): ds.add s.view
          jsonOk(Http200, %*{"organization": slugL, "directories": ds, "mappings": lc.mappings(orgL.id), "accounts": lc.accounts(orgL.id)})
        elif partsL.len == 4 and partsL[2] == "servers":
          let rawName = partsL[3]
          let colonL = rawName.find(':')
          let nameL = if colonL >= 0: rawName[0 ..< colonL] else: rawName
          let actionL = if colonL >= 0: rawName[colonL + 1 .. ^1] else: ""
          if actionL == "" and lmeth == "PUT":
            let sj = try: parseJson(getBody()) except JsonParsingError: nil
            let done = lc.putServer(vkL.kek, vkL.ready, orgL.id, nameL, sj, nowL)
            if done.error.len > 0:
              problem(HttpCode(done.status), "invalid_directory", done.error)
              return
            lc.record(nowL, actorOf(who), "ldap.put", slugL & "/" & nameL, "ok", (if sj != nil and sj.kind == JObject: sj{"url"}.getStr else: "") & (if lc.serverNamed(orgL.id, nameL).server.warningsOf.len > 0: " (with a warning: " & lc.serverNamed(orgL.id, nameL).server.warningsOf.join(" ") & ")" else: ""))
            jsonOk(if done.created: Http201 else: Http200, lc.serverNamed(orgL.id, nameL).server.view)
          elif actionL == "" and lmeth == "DELETE":
            if not lc.deleteServer(orgL.id, nameL):
              problem(Http404, "not_found", "no such directory")
              return
            lc.record(nowL, actorOf(who), "ldap.delete", slugL & "/" & nameL, "ok")
            jsonOk(Http200, %*{"organization": slugL, "directory": nameL, "deleted": true})
          elif actionL in ["check", "sync"] and lmeth == "POST":
            let found = lc.serverNamed(orgL.id, nameL)
            if not found.found:
              problem(Http404, "not_found", "no such directory")
              return
            if actionL == "check":
              let cj = try: (if getBody().strip.len == 0: newJObject() else: parseJson(getBody())) except JsonParsingError: nil
              if cj == nil or cj.kind != JObject:
                problem(Http400, "invalid_request", "the body is empty or {\"user\": \"ann\"}")
                return
              jsonOk(Http200, lc.checkServer(vkL.kek, vkL.ready, found.server, cj{"user"}.getStr))
            else:
              let rep = lc.syncServer(vkL.kek, vkL.ready, found.server, nowL)
              lc.record(nowL, actorOf(who), "ldap.sync_now", slugL & "/" & nameL, (if rep.error.len == 0: "ok" else: "failed"), rep.error)
              jsonOk(Http200, %*{"directory": nameL, "checked": rep.checked, "switched_off": rep.switchedOff, "switched_on": rep.switchedOn, "roles_changed": rep.changed, "error": rep.error})
          else:
            problem(Http405, "method_not_allowed", "PUT, DELETE, POST :check, POST :sync")
        elif partsL.len == 4 and partsL[2] == "accounts" and lmeth in ["PUT", "DELETE"]:
          if lmeth == "DELETE":
            if not lc.removeAccount(orgL.id, slugL, partsL[3]):
              problem(Http404, "not_found", "no such account of a directory of this organisation")
              return
            lc.record(nowL, actorOf(who), "ldap.account_remove", slugL & ": " & partsL[3], "ok")
            jsonOk(Http200, %*{"account": accountName(partsL[3].toLowerAscii, slugL), "deleted": true})
          else:
            let aj = try: (if getBody().strip.len == 0: newJObject() else: parseJson(getBody())) except JsonParsingError: nil
            if aj == nil or aj.kind != JObject:
              problem(Http400, "invalid_request", "the body is empty or {\"directory\": \"corp\"}")
              return
            let made = lc.makeAccount(vkL.kek, vkL.ready, orgL.id, slugL, partsL[3], aj{"directory"}.getStr, nowL)
            case made.outcome
            of aoMade, aoExists:
              lc.record(nowL, actorOf(who), "ldap.account", made.user, "ok", made.roles.join(","))
              var rs = newJArray()
              for r in made.roles: rs.add %r
              jsonOk(if made.outcome == aoMade: Http201 else: Http200, %*{"account": made.user, "directory": made.detail, "roles_from_directory": rs})
            of aoBadLogin: problem(Http400, "invalid_login", made.detail)
            of aoNoDirectory: problem(Http404, "no_directory", made.detail)
            of aoNotFound: problem(Http404, "person_not_found", made.detail)
            of aoAmbiguous: problem(Http409, "ambiguous_login", made.detail)
            of aoTaken: problem(Http409, "account_taken", made.detail)
            of aoUnavailable: problem(Http503, "directory_unavailable", made.detail)
        elif partsL.len == 3 and partsL[2] == "mappings" and lmeth == "POST":
          let mj = try: parseJson(getBody()) except JsonParsingError: nil
          if mj == nil or mj.kind != JObject or not mj.isString("group_dn") or not mj.isString("role"):
            problem(Http400, "invalid_request", "{\"group_dn\": \"cn=ci-admins,ou=groups,dc=example,dc=org\", \"role\": \"dev\", \"directory\": \"corp\" (optional)} is required")
            return
          let made = lc.addMapping(orgL.id, mj{"directory"}.getStr, mj["group_dn"].getStr, mj["role"].getStr, nowL)
          if made.error.len > 0:
            problem(HttpCode(made.status), "invalid_mapping", made.error)
            return
          lc.record(nowL, actorOf(who), "ldap.map", slugL & ": " & mj["group_dn"].getStr, "ok", "role " & mj["role"].getStr)
          jsonOk(Http201, %*{"id": made.id, "group_dn": normDn(mj["group_dn"].getStr), "role": mj["role"].getStr, "directory": mj{"directory"}.getStr})
        elif partsL.len == 4 and partsL[2] == "mappings" and lmeth == "DELETE":
          if not lc.deleteMapping(orgL.id, partsL[3]):
            problem(Http404, "not_found", "no such mapping")
            return
          lc.record(nowL, actorOf(who), "ldap.unmap", slugL & ": " & partsL[3], "ok")
          jsonOk(Http200, %*{"id": partsL[3], "deleted": true})
        else:
          problem(Http404, "not_found", "no such route")
        return
      if path.startsWith("/api/v1/organizations/") and "/oidc/" in path:
        # D-102: the providers of an organisation (GET; PUT|DELETE .../oidc/providers/{id|new}, the shard\'s) and the map of claim values to roles (GET, POST, DELETE .../oidc/mappings[/{id}])
        let oparts = path["/api/v1/organizations/".len .. ^1].split('/')
        var xc = newRq(coreRef.rqliteUrl)
        let xorg = xc.organizationRow(oparts[0])
        if xorg.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & oparts[0])
          return
        let xnow = getTime().toUnix()
        if oparts.len >= 3 and oparts[2] == "providers":
          if oparts.len == 3 and getMethod() == "GET":
            var arr = newJArray()
            for p in xc.providersOf(xorg.id): arr.add p.view
            jsonOk(Http200, %*{"providers": arr})
          elif oparts.len == 4 and getMethod() == "PUT":
            let pj = try: parseJson(getBody()) except JsonParsingError: nil
            let vk = vaultKek()
            let made = xc.putProvider(vk.kek, vk.ready, xorg.id, (if oparts[3] == "new": "" else: oparts[3]), pj, xnow)
            if made.error.len > 0:
              problem(Http400, "invalid_provider", made.error)
              return
            xc.record(xnow, actorOf(who), "oidc.provider", oparts[0] & ": " & made.id, "ok")
            jsonOk(Http200, xc.providerById(xorg.id, made.id).view)
          elif oparts.len == 4 and getMethod() == "DELETE":
            if not xc.deleteProvider(xorg.id, oparts[3]):
              problem(Http404, "not_found", "no such provider")
              return
            xc.record(xnow, actorOf(who), "oidc.provider.delete", oparts[0] & ": " & oparts[3], "ok")
            jsonOk(Http200, %*{"deleted": true})
          else:
            problem(Http405, "method_not_allowed", "GET /providers, PUT and DELETE /providers/{id} (PUT /providers/new makes one)")
        elif oparts.len >= 3 and oparts[2] == "mappings":
          if oparts.len == 3 and getMethod() == "GET":
            jsonOk(Http200, %*{"mappings": xc.listOidcMappings(xorg.id)})
          elif oparts.len == 3 and getMethod() == "POST":
            let mj = try: parseJson(getBody()) except JsonParsingError: nil
            if mj == nil or not mj.isString("provider") or not mj.isString("claim_value") or not mj.isString("role"):
              problem(Http400, "invalid_request", "{\"provider\": \"id\", \"claim_value\": \"group\", \"role\": \"dev\"} is required")
              return
            let made = xc.putOidcMapping(xorg.id, mj["provider"].getStr, mj["claim_value"].getStr, mj["role"].getStr, xnow)
            if made.error.len > 0:
              problem(Http400, "invalid_mapping", made.error)
              return
            xc.record(xnow, actorOf(who), "oidc.map", oparts[0] & ": " & mj["claim_value"].getStr & " -> " & mj["role"].getStr, "ok")
            jsonOk(Http201, %*{"id": made.id})
          elif oparts.len == 4 and getMethod() == "DELETE":
            if not xc.deleteOidcMapping(xorg.id, oparts[3]):
              problem(Http404, "not_found", "no such mapping")
              return
            xc.record(xnow, actorOf(who), "oidc.unmap", oparts[0] & ": " & oparts[3], "ok")
            jsonOk(Http200, %*{"deleted": true})
          else:
            problem(Http405, "method_not_allowed", "GET and POST /mappings, DELETE /mappings/{id}")
        else:
          problem(Http404, "not_found", "no such route")
        return
      if path.startsWith("/api/v1/organizations/") and "/identities" in path:
        # D-100: who a login of the host of the repositories is in CiNim. GET /organizations/{slug}/identities; PUT|DELETE .../identities/{provider}/{login} ({"user": "..."})
        let iparts = path["/api/v1/organizations/".len .. ^1].split('/')
        if iparts.len < 2 or iparts[1] != "identities" or iparts.len notin [2, 4]:
          problem(Http404, "not_found", "no such route")
          return
        var ic = newRq(coreRef.rqliteUrl)
        let iorg = ic.organizationRow(iparts[0])
        if iorg.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & iparts[0])
          return
        if iparts.len == 2:
          if getMethod() != "GET":
            problem(Http405, "method_not_allowed", "GET")
            return
          jsonOk(Http200, %*{"identities": ic.listIdentities(iorg.id)})
        elif getMethod() == "PUT":
          let ij = try: parseJson(getBody()) except JsonParsingError: nil
          if ij == nil or not ij.isString("user"):
            problem(Http400, "invalid_request", "{\"user\": \"account\"} is required")
            return
          let bad = ic.setIdentity(iorg.id, iparts[2], iparts[3], ij["user"].getStr)
          if bad.len > 0:
            problem(Http400, "invalid_identity", bad)
            return
          ic.record(getTime().toUnix(), actorOf(who), "identity.set", iparts[0] & ": " & iparts[2] & ":" & iparts[3], "ok", ij["user"].getStr)
          jsonOk(Http200, %*{"provider": iparts[2], "login": iparts[3].toLowerAscii, "user": ij["user"].getStr})
        elif getMethod() == "DELETE":
          if not ic.deleteIdentity(iorg.id, iparts[2], iparts[3]):
            problem(Http404, "not_found", "no such identity")
            return
          ic.record(getTime().toUnix(), actorOf(who), "identity.delete", iparts[0] & ": " & iparts[2] & ":" & iparts[3], "ok")
          jsonOk(Http200, %*{"deleted": true})
        else:
          problem(Http405, "method_not_allowed", "PUT or DELETE")
        return
      if path.startsWith("/api/v1/organizations/") and path.endsWith("/access") and path.count('/') == 5:
        # D-98: the roles of an organisation as a document (core/accesscode.nim). GET writes it; PUT reads it: ?dry_run=true says what would change, ?prune=true also takes away the hand-given roles it does not name
        let accSlug = path["/api/v1/organizations/".len ..< path.len - "/access".len]
        var xc = newRq(coreRef.rqliteUrl)
        let accOrg = xc.organizationRow(accSlug)
        if accOrg.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & accSlug)
          return
        if getMethod() == "GET":
          jsonOk(Http200, xc.exportAccess(accOrg.id, accSlug))
        elif getMethod() == "PUT":
          var prune, dry = false
          if qpos >= 0:
            for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
              if k == "prune": prune = v == "true"
              if k == "dry_run": dry = v == "true"
          let doc = try: parseJson(getBody()) except JsonParsingError: nil
          let done = xc.applyAccess(accOrg.id, accSlug, doc, prune, dry, who.user, getTime().toUnix())
          if done.errors.len > 0:
            problem(Http400, "invalid_access", done.errors.join("; "))
            return
          if not dry: xc.record(getTime().toUnix(), actorOf(who), "access.apply", accSlug, "ok", $done.changes.len & " changes" & (if prune: ", prune" else: ""))
          jsonOk(Http200, %*{"dry_run": dry, "changes": done.changes})
        else:
          problem(Http405, "method_not_allowed", "GET or PUT")
        return
      if path.startsWith("/api/v1/organizations/") and "/members" in path:
        # D-84: who has which role in an organisation, or on a group or project of it. Read with `access.read`, changed with `access.write` (the gate has checked it for this organisation
        # and group): the roles of an existing user there are replaced, or taken away. Users are made by an administrator of the shard (POST /api/v1/users).
        #   /organizations/{slug}/members[/{user}]                       in the organisation
        #   /organizations/{slug}/groups|projects/{path}/members[/{user}] on the group or project (and what is under it)
        let afterOrg = path["/api/v1/organizations/".len .. ^1]
        let parts = afterOrg.split('/')
        let memberAt = parts.find("members")
        var memberOrg, memberGroup, memberUser = ""
        # a subject is a person (an account) or a team, `team:<name>` (D-91)
        func isSubject(s: string): bool = validAccountName(s) or (s.startsWith("team:") and validTeamName(s[5 .. ^1]))
        var shapeOk = parts.len >= 2 and memberAt >= 1 and memberAt >= parts.len - 2 and (memberAt == parts.len - 1 or isSubject(parts[memberAt + 1]))
        if shapeOk:
          memberOrg = parts[0]
          if memberAt > 1:
            shapeOk = parts[1] in ["groups", "projects"] and memberAt > 2
            memberGroup = parts[2 ..< memberAt].join("/")
          if memberAt < parts.len - 1:
            memberUser = parts[memberAt + 1]
            if memberUser.startsWith("team:"): memberUser = teamSubject(memberOrg, memberUser[5 .. ^1])          # kept as `team:<slug>/<name>`
        if not shapeOk:
          problem(Http404, "not_found", "no such route")
          return
        var mc = newRq(coreRef.rqliteUrl)
        let memberOrgRow = mc.organizationRow(memberOrg)
        if memberOrgRow.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & memberOrg)
          return
        if memberGroup.len > 0:
          let hg = mc.groupIdOf(memberOrgRow.id, memberGroup)
          if not hg.found or hg.id.len == 0:
            problem(Http404, "group_not_found", "the organisation " & memberOrg & " has no group or project " & memberGroup)
            return
          memberGroup = normalPath(memberGroup)
        let memberScope = "org:" & memberOrg & (if memberGroup.len > 0: "/" & memberGroup else: "")
        let mmeth = getMethod()
        if memberUser.len == 0 and mmeth == "GET":
          jsonOk(Http200, %*{"organization": memberOrg, "group": memberGroup, "members": mc.listMembers(memberScope)})
        elif memberUser.len > 0 and mmeth == "PUT":
          let mj = try: parseJson(getBody()) except JsonParsingError: nil
          if mj == nil or mj.kind != JObject or mj{"roles"}.isNil or mj{"roles"}.kind != JArray:
            problem(Http400, "invalid_request", "{\"roles\": [\"dev\", ...]} is required (an empty list takes the roles away)")
            return
          # a role is its name, or (D-92) {"role": "dev", "expires_at": <unix seconds or RFC 3339>, "only_own": true, "refs": ["main", "release/*"]}
          var given: seq[string]
          var conds = initTable[string, BindingCondition]()
          var badRole = ""
          for x in mj["roles"].elems:
            if x.kind == JString: given.add x.getStr
            elif x.kind == JObject and x.isString("role"):
              let parsed = bindingConditionOf(x)
              if parsed.error.len > 0:
                badRole = parsed.error
                break
              given.add x["role"].getStr
              conds[x["role"].getStr] = parsed.cond
            else:
              badRole = "a role is its name, or {\"role\": \"...\", \"expires_at\": ..., \"only_own\": true, \"refs\": [...]}"
              break
          if badRole.len > 0:
            problem(Http400, "invalid_request", badRole)
            return
          let bad = mc.setMember(memberScope, memberUser, given, conds)
          if bad.len > 0:
            problem(Http400, "invalid_member", bad)
            return
          mc.record(getTime().toUnix(), actorOf(who), "member.set", memberUser & " at " & memberScope, "ok", given.join(",") & (if conds.len > 0: " (tied)" else: ""))
          var saved = newJObject()
          for m in mc.listMembers(memberScope):
            if m["user"].getStr == memberUser and m.hasKey("conditions"): saved = m["conditions"]
          jsonOk(Http200, %*{"organization": memberOrg, "group": memberGroup, "user": memberUser, "roles": given, "conditions": saved})
        elif memberUser.len > 0 and mmeth == "DELETE":
          let bad = mc.setMember(memberScope, memberUser, @[])
          if bad.len > 0:
            problem(Http404, "not_found", bad)
            return
          mc.record(getTime().toUnix(), actorOf(who), "member.remove", memberUser & " at " & memberScope, "ok")
          jsonOk(Http200, %*{"organization": memberOrg, "group": memberGroup, "user": memberUser, "roles": []})
        else:
          problem(Http405, "method_not_allowed", "GET on /members, PUT and DELETE on /members/{user}")
        return
      if path.startsWith("/api/v1/organizations/") and "/secrets" in path:
        # the secrets that steps may ask for (core/stepsecrets.nim): names and versions are in the database, the values sealed there. The value is read from the body and is not logged
        # or answered. D-86: a secret is the organisation's or a group's or a project's (its runs see the nearest one by name), and may be `protected`:
        #   /organizations/{slug}/secrets[/NAME]                          the organisation's
        #   /organizations/{slug}/groups|projects/{path}/secrets[/NAME]   a group's or project's; GET ...?effective=true lists what a run of it can ask for, and from where
        let rest = path["/api/v1/organizations/".len .. ^1]
        let segsS = rest.split('/')
        let secAt = segsS.find("secrets")
        var slug, secGroup, secName = ""
        var secShape = segsS.len >= 2 and secAt >= 1 and secAt >= segsS.len - 2
        if secShape:
          slug = segsS[0]
          if secAt > 1:
            secShape = segsS[1] in ["groups", "projects"] and secAt > 2
            secGroup = normalPath(segsS[2 ..< secAt].join("/"))
          if secAt < segsS.len - 1: secName = segsS[secAt + 1]
        if not secShape or slug.len == 0:
          problem(Http404, "not_found", "no such route")
          return
        var c = newRq(coreRef.rqliteUrl)
        let org = c.organizationRow(slug)
        if org.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slug)
          return
        var secGroupId = ""
        if secGroup.len > 0:
          let sg = c.groupIdOf(org.id, secGroup)
          if not sg.found or sg.id.len == 0:
            problem(Http404, "group_not_found", "the organisation " & slug & " has no group or project " & secGroup)
            return
          secGroupId = sg.id
        let smeth = getMethod()
        if smeth == "GET" and secName.len == 0:
          var asked = false
          if qpos >= 0:
            for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
              if k == "effective": asked = v == "true"
          if asked: jsonOk(Http200, %*{"organization": slug, "project": secGroup, "secrets": c.effectiveSecrets(org.id, secGroupId)})
          else: jsonOk(Http200, %*{"organization": slug, "group": secGroup, "secrets": c.listStepSecrets(org.id, secGroupId)})
          return
        if secName.len == 0:
          problem(Http405, "method_not_allowed", "GET lists, PUT and DELETE name a secret: /secrets/{NAME}")
          return
        let nameProblem = checkName(secName)
        if nameProblem.len > 0:
          problem(Http400, "invalid_name", nameProblem)
          return
        let vk = vaultKek()
        if not vk.ready:
          reply(Http503, $(%*{"type": "about:blank", "status": 503, "code": "secrets_unavailable", "detail": vaultError()}),
                ["Content-Type: application/problem+json", "Retry-After: 15"])
          return
        if smeth == "PUT":
          if org.state != "active":
            problem(Http409, "organization_disabled", "the organisation " & slug & " is switched off")
            return
          let j = try: parseJson(getBody()) except JsonParsingError: nil
          if j == nil or j.kind != JObject or not j.hasKey("value") or j["value"].kind != JString:
            problem(Http400, "invalid_request", "the body is {\"value\": \"...\"}")
            return
          let value = j["value"].getStr
          let valueProblem = checkValue(value)
          if valueProblem.len > 0:
            problem(Http400, "invalid_value", valueProblem)
            return
          let makeProtected = j{"protected"}.getBool
          let put = c.putSecret(vk.kek, org.id, secName, value, getTime().toUnix(), secGroupId, makeProtected)
          if not put.ok:
            if put.retry:
              reply(Http503, $(%*{"type": "about:blank", "status": 503, "code": "secrets_unavailable", "detail": put.error}),
                    ["Content-Type: application/problem+json", "Retry-After: 15"])
            else:
              problem(Http500, "secrets_error", put.error)
            return
          let auditName = (if secGroup.len > 0: secGroup & ":" else: "") & secName
          c.recordSecret(c.variableAuditMode(org.id), coreSecret(coreRef.certs), org.id, getTime().toUnix(), who, slug, auditName, put.version, some(value))
          jsonOk(Http200, %*{"organization": slug, "group": secGroup, "name": secName, "version": put.version, "protected": makeProtected})
        elif smeth == "DELETE":
          if not c.forgetStepSecret(org.id, secName, secGroupId):
            problem(Http404, "not_found", "no such secret")
            return
          c.recordSecret(c.variableAuditMode(org.id), coreSecret(coreRef.certs), org.id, getTime().toUnix(), who, slug, (if secGroup.len > 0: secGroup & ":" else: "") & secName, 0, none(string))
          jsonOk(Http200, %*{"organization": slug, "group": secGroup, "name": secName, "deleted": true})
        else:
          problem(Http405, "method_not_allowed", "PUT or DELETE")
        return
      if path.startsWith("/api/v1/organizations/") and ("/groups" in path or "/projects" in path):
        # PRJ-001, D-54: the groups of an organisation, nested up to 8 levels, and their variables (inherited by the groups below and by the runs in them).
        #   GET /groups                      the groups, by path
        #   PUT|GET|DELETE /groups/{path}    make (the parent has to exist), show, remove (only an empty one) the group at a path such as team/backend
        #   /groups/{path}/variables[/NAME]  the variables of the group
        let restG = path["/api/v1/organizations/".len .. ^1]
        # D-68: a group is a folder and a project is a leaf with a repository; two things one makes, `/groups` and `/projects`, both served here (a node is one or the other, and its
        # variables, settings and hold are under either prefix)
        let gi = restG.find("/groups")
        let pi = restG.find("/projects")
        let onProjects = pi >= 0 and (gi < 0 or pi < gi)
        let word = if onProjects: "/projects" else: "/groups"
        let slugG = restG.split(word)[0]
        let afterG = restG[slugG.len .. ^1]            # "/groups", "/groups/a/b", "/groups/a/b/variables/NAME", "/projects/a/b"
        if slugG.len == 0 or not (afterG == word or afterG.startsWith(word & "/")):
          problem(Http404, "not_found", "no such route")
          return
        var gc = newRq(coreRef.rqliteUrl)
        let orgG = gc.organizationRow(slugG)
        if orgG.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugG)
          return
        let gpath = afterG[word.len .. ^1].strip(chars = {'/'})
        let gmeth = getMethod()
        if gpath.len == 0:
          if gmeth != "GET":
            problem(Http405, "method_not_allowed", "GET lists; PUT " & word & "/{path} makes one")
            return
          var items = newJArray()
          for g in gc.listGroups(orgG.id):
            if (g.repository.len > 0) != onProjects: continue            # /groups lists the folders, /projects the projects
            if not who.mayIn("group.read", slugG, g.path): continue      # D-84: the ones the caller may see
            if onProjects: items.add %*{"path": g.path, "depth": g.depth, "repository": g.repository}
            else: items.add %*{"path": g.path, "depth": g.depth}
          jsonOk(Http200, %*{"organization": slugG, (if onProjects: "projects" else: "groups"): items})
          return
        # a path, and perhaps /variables and a name after it, or /settings ('variables' and 'settings' cannot be the name of a group)
        let segs = gpath.split('/')
        if segs.len >= 2 and segs[^1] == "hold":
          # DAT-006: a legal hold on a group and the groups below it
          let hp = segs[0 ..< segs.high].join("/")
          let hg = gc.groupIdOf(orgG.id, hp)
          if not hg.found or hg.id.len == 0:
            problem(Http404, "group_not_found", "the organisation " & slugG & " has no group " & hp)
            return
          gc.serveScopeHold(orgG.id, slugG, hg.id, normalPath(hp), who)
          return
        if segs.len >= 2 and segs[^1] == "settings":
          # DAT-004: the cache limits of a group: cache_quota_bytes (its own pool: the entries of the group and the groups below it) and cache_retention_days (0: the level above decides)
          let sp = segs[0 ..< segs.high].join("/")
          let sg = gc.groupIdOf(orgG.id, sp)
          if not sg.found or sg.id.len == 0:
            problem(Http404, "group_not_found", "the organisation " & slugG & " has no group " & sp)
            return
          if gmeth == "PUT":
            let sj = try: parseJson(getBody()) except JsonParsingError: nil
            if sj == nil or sj.kind != JObject:
              problem(Http400, "invalid_request", "a JSON object with cache_quota_bytes, cache_retention_days, protected_refs and/or allowed_profiles is required")
              return
            # D-86: the refs that are protected (a project's) and the privileged profiles its pipelines may use are security settings, each with a permission of its own
            var newRefs, newProfiles: seq[string]
            for k in ["protected_refs", "allowed_profiles"]:
              if not sj.hasKey(k): continue
              if sj[k].kind != JArray:
                problem(Http400, "invalid_request", k & " must be a list of strings")
                return
              for x in sj[k].elems:
                if x.kind != JString:
                  problem(Http400, "invalid_request", k & " must be a list of strings")
                  return
                if k == "protected_refs": newRefs.add x.getStr
                else: newProfiles.add x.getStr
            if sj.hasKey("protected_refs"):
              if not who.mayIn("ref.protect", slugG, sp):
                problem(Http403, "forbidden", "protected_refs needs ref.protect on " & normalPath(sp))
                return
              if gc.resolveProject(orgG.id, sp).code.len > 0:
                problem(Http409, "not_a_project", "protected refs belong to a project (a group with a repository), and " & normalPath(sp) & " is not one")
                return
            if sj.hasKey("allowed_profiles") and not who.mayIn("profile.grant", slugG, sp):
              problem(Http403, "forbidden", "allowed_profiles needs profile.grant on " & normalPath(sp))
              return
            if sj.hasKey("status"):
              # D-96: where the state of the runs of this project is told
              if not who.mayIn("status.configure", slugG, sp):
                problem(Http403, "forbidden", "status needs status.configure on " & normalPath(sp))
                return
              if gc.resolveProject(orgG.id, sp).code.len > 0:
                problem(Http409, "not_a_project", "a status belongs to a project (a group with a repository), and " & normalPath(sp) & " is not one")
                return
              let badStatus = gc.setStatusTarget(sg.id, sj["status"])
              if badStatus.len > 0:
                problem(Http400, "invalid_request", badStatus)
                return
              gc.record(getTime().toUnix(), actorOf(who), "project.status", slugG & "/" & normalPath(sp), "ok", (if sj["status"].kind == JObject: sj["status"]{"repository"}.getStr else: "cleared"))
            if sj.hasKey("allowed_callers"):
              # D-95: the projects whose pipelines may start runs of this project with ci.trigger
              if sj["allowed_callers"].kind != JArray:
                problem(Http400, "invalid_request", "allowed_callers must be a list of project or group paths")
                return
              var callers: seq[string]
              for x in sj["allowed_callers"].elems:
                if x.kind != JString:
                  problem(Http400, "invalid_request", "allowed_callers must be a list of project or group paths")
                  return
                callers.add x.getStr
              if not who.mayIn("caller.allow", slugG, sp):
                problem(Http403, "forbidden", "allowed_callers needs caller.allow on " & normalPath(sp))
                return
              if gc.resolveProject(orgG.id, sp).code.len > 0:
                problem(Http409, "not_a_project", "callers belong to a project (a group with a repository), and " & normalPath(sp) & " is not one")
                return
              let badCallers = gc.setAllowedCallers(sg.id, callers)
              if badCallers.len > 0:
                problem(Http400, "invalid_request", badCallers)
                return
              gc.record(getTime().toUnix(), actorOf(who), "project.allowed_callers", slugG & "/" & normalPath(sp), "ok", callers.join(","))
            if sj.hasKey("required_approvals"):
              # D-93: how many approvals the runs of this project that wait for approval need
              if sj["required_approvals"].kind != JInt or sj["required_approvals"].getInt < 1 or sj["required_approvals"].getInt > maxRequiredApprovals:
                problem(Http400, "invalid_request", "required_approvals is a whole number from 1 to " & $maxRequiredApprovals)
                return
              if not who.mayIn("approval.configure", slugG, sp):
                problem(Http403, "forbidden", "required_approvals needs approval.configure on " & normalPath(sp))
                return
              if gc.resolveProject(orgG.id, sp).code.len > 0:
                problem(Http409, "not_a_project", "approvals belong to a project (a group with a repository), and " & normalPath(sp) & " is not one")
                return
              gc.setRequiredApprovals(sg.id, sj["required_approvals"].getInt)
              gc.record(getTime().toUnix(), actorOf(who), "project.required_approvals", slugG & "/" & normalPath(sp), "ok", $sj["required_approvals"].getInt)
            let cur = gc.groupLimit(sg.id)
            var q = cur.quota
            var d = cur.retentionDays
            for k in ["cache_quota_bytes", "cache_retention_days"]:
              if sj.hasKey(k) and sj[k].kind != JInt:
                problem(Http400, "invalid_request", k & " must be an integer")
                return
            if sj.hasKey("cache_quota_bytes"): q = sj["cache_quota_bytes"].getBiggestInt
            if sj.hasKey("cache_retention_days"): d = sj["cache_retention_days"].getBiggestInt
            let bad = validGroupLimit(q, d)
            if bad.len > 0:
              problem(Http400, "invalid_request", bad)
              return
            if sj.hasKey("protected_refs"):
              let bad = gc.setProtectedRefs(sg.id, newRefs)
              if bad.len > 0:
                problem(Http400, "invalid_request", bad)
                return
              gc.record(getTime().toUnix(), actorOf(who), "project.protected_refs", slugG & "/" & normalPath(sp), "ok", newRefs.join(","))
            if sj.hasKey("allowed_profiles"):
              let bad = gc.setAllowedProfiles(sg.id, newProfiles)
              if bad.len > 0:
                problem(Http400, "invalid_request", bad)
                return
              gc.record(getTime().toUnix(), actorOf(who), "project.allowed_profiles", slugG & "/" & normalPath(sp), "ok", newProfiles.join(","))
            gc.setGroupLimit(sg.id, q, d)
          elif gmeth != "GET":
            problem(Http405, "method_not_allowed", "GET or PUT")
            return
          let lim = gc.groupLimit(sg.id)
          jsonOk(Http200, %*{"organization": slugG, "group": normalPath(sp), "cache_quota_bytes": lim.quota, "cache_retention_days": lim.retentionDays,
                             "effective_cache_retention_seconds": gc.retentionSeconds(orgG.id, sg.id, cacheRetentionFromEnv()), "required_approvals": gc.requiredApprovals(sg.id), "allowed_callers": gc.allowedCallers(sg.id), "status": gc.statusTargetOf(sg.id).viewOf,
                             "protected_refs": gc.protectedPatterns(sg.id), "effective_allowed_profiles": gc.allowedProfiles(sg.id)})
          return
        let vpos = segs.find("variables")
        let groupPath = if vpos >= 0: segs[0 ..< vpos].join("/") else: gpath
        let varName = if vpos >= 0 and vpos + 1 < segs.len: segs[vpos + 1 .. ^1].join("/") else: ""
        if vpos >= 0 and (vpos == 0 or vpos + 2 < segs.len):
          problem(Http404, "not_found", "no such route")
          return
        if vpos >= 0:
          let g = gc.groupIdOf(orgG.id, groupPath)
          if not g.found or g.id.len == 0:
            problem(Http404, "group_not_found", "the organisation " & slugG & " has no group " & groupPath)
            return
          gc.serveVariables(vsGroup, g.id, varName, %*{"organization": slugG, "group": normalPath(groupPath)},
                          VarAudit(tenantId: orgG.id, level: "group " & slugG & "/" & normalPath(groupPath), master: coreSecret(coreRef.certs), who: who))
          return
        if gmeth == "PUT":
          let body = getBody()
          let gj = if body.strip.len > 0: (try: parseJson(body) except JsonParsingError: nil) else: newJObject()
          if gj == nil or gj.kind != JObject:
            problem(Http400, "invalid_request", "the body is empty or a JSON object")
            return
          if onProjects:
            # D-68: a project is made with its main repository (a leaf of the tree); the same call again changes the repository
            if not gj.hasKey("repository") or gj["repository"].kind != JString:
              problem(Http400, "invalid_request", "a project has a repository: {\"repository\": \"https://...\"}")
              return
            let made = gc.createProject(orgG.id, groupPath, gj["repository"].getStr, getTime().toUnix())
            if made.error.len > 0:
              problem((if made.code == "already_a_group": Http409 else: Http400), (if made.code.len > 0: made.code else: "invalid_project"), made.error)
              return
            jsonOk(if made.created: Http201 else: Http200, %*{"organization": slugG, "project": normalPath(groupPath), "created": made.created, "repository": gj["repository"].getStr})
          else:
            # a group is a folder: it has no repository (a project is made with PUT /projects/{path})
            if gj.hasKey("repository"):
              problem(Http400, "invalid_request", "a group has no repository, it is a folder: a project is made with PUT /projects/{path}")
              return
            if gc.groupKind(orgG.id, groupPath) == gkProject:
              problem(Http409, "already_a_project", "there is a project at " & normalPath(groupPath) & ", not a group")
              return
            let made = gc.createGroup(orgG.id, groupPath, getTime().toUnix())
            if made.error.len > 0:
              problem(Http400, "invalid_group", made.error)
              return
            jsonOk(if made.created: Http201 else: Http200, %*{"organization": slugG, "group": normalPath(groupPath), "created": made.created})
        elif gmeth == "GET":
          let g = gc.groupIdOf(orgG.id, groupPath)
          if not g.found:
            problem(Http404, "group_not_found", "the organisation " & slugG & " has no group " & groupPath)
            return
          let pr = gc.resolveProject(orgG.id, groupPath)
          jsonOk(Http200, %*{"organization": slugG, "path": normalPath(groupPath), "kind": (if pr.code == "": "project" else: "group"), "repository": pr.repository})
        elif gmeth == "DELETE":
          let gone = gc.deleteGroup(orgG.id, groupPath)
          if gone.error.len > 0:
            problem(Http409, "group_not_empty", gone.error)
            return
          if not gone.deleted:
            problem(Http404, "group_not_found", "the organisation " & slugG & " has no group " & groupPath)
            return
          jsonOk(Http200, %*{"organization": slugG, "group": normalPath(groupPath), "deleted": true})
        else:
          problem(Http405, "method_not_allowed", "GET, PUT or DELETE")
        return
      if path.startsWith("/api/v1/organizations/") and "/variables" in path:
        # VAR-001: the plain variables of an organisation, for its steps' environment (core/orgvars.nim). GET lists (any role that reads), PUT and DELETE name one: /variables/{NAME}
        let restV = path["/api/v1/organizations/".len .. ^1]
        let partsV = restV.split("/variables")
        let slugV = partsV[0]
        let varName = if partsV.len > 1: partsV[1].strip(chars = {'/'}) else: ""
        if partsV.len != 2 or (partsV[1].len > 0 and not partsV[1].startsWith("/")) or slugV.len == 0:
          problem(Http404, "not_found", "no such route")
          return
        var vc = newRq(coreRef.rqliteUrl)
        let orgV = vc.organizationRow(slugV)
        if orgV.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugV)
          return
        vc.serveVariables(vsOrganization, orgV.id, varName, %*{"organization": slugV},
                          VarAudit(tenantId: orgV.id, level: "organization " & slugV, master: coreSecret(coreRef.certs), who: who))
        return
      if path.startsWith("/api/v1/organizations/") and (path.endsWith("/locks") or "/locks/" in path):
        # PIP-014: the jobs in which the locks of an organisation are present - who holds a lock and who waits for it, in the order they will get it
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        let restL = path["/api/v1/organizations/".len .. ^1]
        let partsL = restL.split("/locks", maxsplit = 1)
        let slugL = partsL[0]
        let lockName = if partsL.len > 1: partsL[1].strip(chars = {'/'}) else: ""
        var lc = newRq(coreRef.rqliteUrl)
        let orgL = lc.organizationRow(slugL)
        if slugL.len == 0 or orgL.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugL)
          return
        if lockName.len > 0 and not validLockName(lockName):
          problem(Http400, "invalid_request", "a lock is a name of 1 to 64 letters, digits and . _ : -")
          return
        let profileL = lc.ensureOrganizationProfile(orgL.id, namespaceName(orgPrefix, orgShard, slugL))
        let view = lc.lockView(profileL, lockName)
        if lockName.len > 0:
          if view.len == 0:
            jsonOk(Http200, %*{"organization": slugL, "name": lockName, "holder": nil, "waiting": []})
          else:
            var one = view[0]
            one["organization"] = %slugL
            jsonOk(Http200, one)
        else:
          jsonOk(Http200, %*{"organization": slugL, "locks": view})
        return
      if path.startsWith("/api/v1/organizations/") and "/triggers" in path:
        # the triggers of an organisation (core/triggers.nim): an administrator's calls
        let rest = path["/api/v1/organizations/".len .. ^1]
        let parts = rest.split("/triggers", maxsplit = 1)
        let slug = parts[0]
        let tail = if parts.len > 1: parts[1] else: ""
        if parts.len != 2 or slug.len == 0 or (tail.len > 0 and not tail.startsWith("/")):
          problem(Http404, "not_found", "no such route")
          return
        var c = newRq(coreRef.rqliteUrl)
        let org = c.organizationRow(slug)
        if org.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slug)
          return
        let tmeth = getMethod()
        let target = tail.strip(chars = {'/'})
        let colon = target.find(':')
        let tid = if colon >= 0: target[0 ..< colon] else: target
        let action = if colon >= 0: target[colon + 1 .. ^1] else: ""
        if tid.len == 0:
          if tmeth == "GET":
            var items = newJArray()
            for t in c.listTriggers(org.id):
              if who.mayIn("trigger.read", slug, t.groupPath): items.add t.view
            jsonOk(Http200, %*{"organization": slug, "triggers": items})
          elif tmeth == "POST":
            if org.state != "active":
              problem(Http409, "organization_disabled", "the organisation " & slug & " is switched off")
              return
            let spec = parseTriggerSpec(try: parseJson(getBody()) except JsonParsingError: nil)
            if spec.error.len > 0:
              problem(Http400, "invalid_request", spec.error)
              return
            if c.nameTaken(org.id, spec.spec.name):
              problem(Http409, "name_taken", "the organisation has a trigger " & spec.spec.name)
              return
            if c.countTriggers(org.id) >= maxTriggersPerOrg:
              problem(Http409, "too_many_triggers", "at most " & $maxTriggersPerOrg & " triggers per organisation")
              return
            if not who.mayIn("trigger.write", slug, spec.spec.groupPath):
              problem(Http403, "forbidden", "you may not make triggers for the project " & spec.spec.groupPath & ": it needs trigger.write there")
              return
            let tg = c.resolveProject(org.id, spec.spec.groupPath)
            if tg.code.len > 0:
              problem((if tg.code == "project_not_found": Http404 else: Http409), tg.code, tg.message)
              return
            let made = c.createTrigger(org.id, spec.spec, getTime().toUnix(), tg.id)
            let created = c.getTrigger(org.id, made.id)
            var body = created.row.view
            if made.secret.len > 0:
              body["secret"] = %made.secret
              body["secret_note"] = %"shown only now; send it as 'Authorization: Bearer <secret>' to the hook"
            jsonOk(Http201, body)
          else:
            problem(Http405, "method_not_allowed", "GET lists, POST creates")
          return
        let found = c.getTrigger(org.id, tid)
        if not found.found or not who.mayUseIn(slug, found.row.groupPath):
          problem(Http404, "not_found", "no such trigger")                   # one in a project the caller may not use is not confirmed
          return
        if action == "" and tmeth == "GET":
          jsonOk(Http200, found.row.view)
        elif action == "" and tmeth == "DELETE":
          discard c.deleteTrigger(org.id, tid)
          jsonOk(Http200, %*{"id": tid, "deleted": true})
        elif tmeth == "POST" and action in ["enable", "disable"]:
          discard c.setEnabled(org.id, tid, action == "enable", getTime().toUnix())
          jsonOk(Http200, c.getTrigger(org.id, tid).row.view)
        elif tmeth == "POST" and action == "rotate-secret":
          let fresh = c.rotateHookSecret(org.id, tid)
          if fresh.len == 0:
            problem(Http409, "not_a_webhook", "only a webhook has a secret")
            return
          jsonOk(Http200, %*{"id": tid, "secret": fresh, "secret_note": "shown only now; the old secret no longer works"})
        elif tmeth == "POST" and action == "fire":
          # a manual start, for any trigger (also a switched-off one); the body may carry {"params": {...}} for this run
          let body = getBody()
          let bj = if body.strip.len == 0: newJObject() else: (try: parseJson(body) except JsonParsingError: nil)
          if bj == nil or bj.kind != JObject:
            problem(Http400, "invalid_request", "the body is empty or {\"params\": {...}}")
            return
          let given = checkParams(bj{"params"})
          if given.error.len > 0:
            problem(Http400, "invalid_params", given.error)
            return
          let wanted = bj{"commit"}.getStr
          if wanted.len > 0 and not scriptsource.validRef(wanted):
            problem(Http400, "invalid_source", "commit is a SHA, a branch or a tag name")
            return
          # D-86: a manual firing that names another ref than the trigger's own, and a protected one, is for those who hold run.start.protected
          if wanted.len > 0 and refNameOf(wanted).len > 0 and c.isProtectedRef(found.row.groupId, refNameOf(wanted)) and not who.mayStart("run.start.protected", slug, found.row.groupPath, refNameOf(wanted)):
            problem(Http403, "protected_ref", "\"" & wanted & "\" is a protected ref of the project " & found.row.groupPath & ": firing a trigger on it needs run.start.protected there")
            return
          # D-92: a role tied to refs starts runs on those refs only, also through a trigger
          if not who.mayFireOn(slug, found.row.groupPath, (if wanted.len > 0: refNameOf(wanted) else: refNameOf(found.row.ref0))):
            problem(Http403, "forbidden", "your role may start runs of " & found.row.groupPath & " on certain refs only; this firing is on another")
            return
          let fired = coreRef.fire(found.row, given.pairs, getTime().toUnix(), commit = wanted, actor = actorOf(who))
          if fired.started:
            jsonOk(Http201, %*{"id": fired.runId, "organization": slug, "trigger_id": tid, "state": coreRef.stateOfRun(fired.runId)})
          elif fired.status != 0:
            problem(HttpCode(fired.status), fired.reason, fired.detail)
          else:
            problem((if fired.reason == "queue_full": Http429 else: Http409), fired.reason, "no run was started: " & fired.reason)
        else:
          problem(Http405, "method_not_allowed", "GET, DELETE, or POST :enable :disable :rotate-secret :fire")
        return
      if path.startsWith("/api/v1/organizations/"):
        # SHD-007: switching an organisation off (DELETE) and deleting it for good (DELETE ?purge=true)
        if getMethod() != "DELETE":
          problem(Http405, "method_not_allowed", "DELETE")
          return
        let slug = path["/api/v1/organizations/".len .. ^1]
        var doPurge, doForce = false
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            if k == "purge": doPurge = v == "true"
            if k == "force": doForce = v == "true"
        var c = newRq(coreRef.rqliteUrl)
        let state = c.organizationState(slug)
        if state.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slug)
          return
        if doPurge and c.heldCount(c.organizationRow(slug).id) > 0:
          problem(Http409, "legal_hold", "runs of this organisation are under a legal hold (GET /api/v1/organizations/" & slug & "/holds); release them first")
          return
        if doPurge and state != "disabled" and not doForce:
          problem(Http409, "not_disabled", "switch the organisation off first (DELETE without purge), or confirm with force=true")
          return
        var r: ProvisionResult
        r.ok = true
        if provisionOn:
          let pc = provisionConfig(currentConfig())
          r = if doPurge: purge(kube, pc, slug) else: disable(kube, pc, slug)
        if not r.ok:
          reply(Http502, $(%*{"type": "about:blank", "status": 502, "code": "deprovision_failed", "step": r.failedStep,
                              "detail": r.error, "done": stepsJson(r)}), ["Content-Type: application/problem+json"])
          return
        if doPurge:
          c.deleteCredentialRow(namespaceName(orgPrefix, orgShard, slug))
          forgetKept(namespaceName(orgPrefix, orgShard, slug))
          c.deleteOrganization(slug)
        else: c.setOrganizationState(slug, "disabled")
        jsonOk(Http200, %*{"slug": slug, "state": (if doPurge: "deleted" else: "disabled"), "kubernetes": stepsJson(r)})
        return
      if path == "/api/v1/router":
        # the data of the organisation switcher and its alerts (SHD-006); without a router it holds this core's own organisations
        var c = newRq(coreRef.rqliteUrl)
        let cfg = currentConfig()
        let view = currentView()
        var own: seq[OwnOrg]
        for o in c.listOrganizationRows():
          if o.state == "active": own.add OwnOrg(slug: o.slug, name: o.name)
        var slugs: seq[string]
        for o in own: slugs.add o.slug
        var items = newJArray()
        for i in view.switcher(own, cfg.publicBase):
          items.add %*{"slug": i.slug, "name": i.name, "url": i.url, "core": i.core}
        var al = newJArray()
        for a in alerts(view.items, cfg.coreId, slugs):
          al.add %*{"code": a.code, "slug": a.slug, "other_core": a.otherCore}
        jsonOk(Http200, %*{"mode": (if view.configured: "multi" else: "single"), "core": cfg.coreId, "shard": orgShard,
                           "router": {"reachable": view.reachable, "registered_at": view.registeredAt, "fetched_at": view.fetchedAt,
                                      "error": view.lastError},
                           "organizations": items, "alerts": al})
        return
      if path == "/api/v1/pipelines:check":
        # PIP-016: the script and the launch parameters are tried by a conductor of the organisation (core/preflight.nim) before a run exists:
        # {"organization": "acme", "script": "...", "params": {...}} -> {"checked": true, "ok": ..., "steps": n, "params": {the parameters a run would have}, "failure": {...}}
        if getMethod() != "POST":
          problem(Http405, "method_not_allowed", "POST")
          return
        let pj = try: parseJson(getBody()) except JsonParsingError: nil
        if pj == nil or pj.kind != JObject or not (pj.isString("script") or pj.isString("project")) or not pj.isString("organization"):
          problem(Http400, "invalid_request", "{\"organization\": \"...\", \"script\": \"...\" or \"project\": \"ci/cinim\", \"commit\": \"...\", \"params\": {...}} is required")
          return
        if pj.hasKey("repository"):
          problem(Http400, "repository_not_accepted", "the repository is the project's: give project, for example cinim or ci/cinim")
          return
        let slugP = pj["organization"].getStr
        if not who.mayUseOrg(slugP):
          problem(Http403, "forbidden", "this token may not use the organisation " & slugP)
          return
        var pc = newRq(coreRef.rqliteUrl)
        let orgP = pc.organizationRow(slugP)
        if orgP.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugP)
          return
        let givenP = checkParams(pj{"params"})
        if givenP.error.len > 0:
          problem(Http400, "invalid_params", givenP.error)
          return
        if pj.isString("project"):
          # D-63, D-68: the script is read from the repository of the project by a conductor of the organisation, then checked; the answer says which commit it was
          let proj = pc.resolveProject(orgP.id, pj["project"].getStr)
          if proj.code.len > 0:
            problem((if proj.code == "project_not_found": Http404 else: Http409), proj.code, proj.message)
            return
          let src = sourceIn(pj, proj.repository)
          if not src.ok:
            problem(Http400, "invalid_source", src.error)
            return
          let ans = checkSource(namespaceName(orgPrefix, orgShard, slugP), src.source, givenP.pairs, currentApiVersion)
          let fp = ans.fetchProblem
          if fp.status != 0 and ans.script.len == 0:
            problem(HttpCode(fp.status), fp.code, fp.message)
            return
          jsonOk(Http200, ans.view)
          return
        jsonOk(Http200, checkScript(namespaceName(orgPrefix, orgShard, slugP), pj["script"].getStr, givenP.pairs, currentApiVersion).view)
        return
      if not path.startsWith(base):
        problem(Http404, "not_found", "no such route")
        return
      let rest = path[base.len .. ^1].strip(chars = {'/'})
      let meth = getMethod()
      if meth == "POST" and rest == "":
        let j = try: parseJson(getBody()) except JsonParsingError: nil
        let wanted = checkRunRequest(j)
        if wanted.code.len > 0:
          problem(Http400, wanted.code, wanted.message)         # D-73: a script is read from git only; one in the request is refused
          return
        # SHD-007: a run belongs to an organisation, whose execution profile places its steps in the organisation's namespace.
        # Without `organization` it belongs to the shard's default tenant and profile (single-tenant setups, development).
        if not who.mayStartSomewhere("run.start", j{"organization"}.getStr, normalPath(j{"project"}.getStr)):
          problem(Http403, "forbidden", "you may not start runs of " & (if j{"organization"}.getStr.len > 0: "the organisation " & j{"organization"}.getStr else: "the shard's default tenant"))
          return
        var tenant = "t1"
        var profile = ""
        var orgSlug = ""
        if j.hasKey("organization"):
          if j["organization"].kind != JString:
            problem(Http400, "invalid_request", "organization must be the slug of an organisation")
            return
          orgSlug = j["organization"].getStr
          var c = newRq(coreRef.rqliteUrl)
          let org = c.organizationRow(orgSlug)
          if org.id.len == 0:
            problem(Http404, "organization_not_found", "this shard has no organisation " & orgSlug)
            return
          if org.state != "active":
            problem(Http409, "organization_disabled", "the organisation " & orgSlug & " is switched off")
            return
          tenant = org.id
          profile = c.ensureOrganizationProfile(org.id, namespaceName(orgPrefix, orgShard, orgSlug))
        let given = checkParams(j{"params"})
        if given.error.len > 0:
          problem(Http400, "invalid_params", given.error)
          return
        # D-68: the run belongs to a project of the organisation (by its path): a leaf of the tree with a repository, which holds the pipelines
        if orgSlug.len == 0:
          problem(Http400, "invalid_request", "a project belongs to an organisation: give organization")
          return
        var gq = newRq(coreRef.rqliteUrl)
        let proj = gq.resolveProject(tenant, j["project"].getStr)
        if proj.code.len > 0:
          problem((if proj.code == "project_not_found": Http404 else: Http409), proj.code, proj.message)
          return
        let groupId = proj.id
        let src = sourceIn(j, proj.repository)
        if not src.ok:
          problem(Http400, "invalid_source", src.error)
          return
        let fromRepo = src.source
        # D-86: a run on a protected ref of the project is for those who hold run.start.protected; asked by a hash it is on no ref
        let askedRef = refNameOf(fromRepo.commit)
        if not who.mayStart("run.start", orgSlug, proj.path, askedRef):          # D-92: a role tied to refs holds for a run on one of them
          problem(Http403, "forbidden", "your role may start runs of " & proj.path & " on certain refs only" & (if askedRef.len > 0: ", and \"" & askedRef & "\" is not one of them" else: ": name the ref"))
          return
        if askedRef.len > 0 and gq.isProtectedRef(groupId, askedRef) and not who.mayStart("run.start.protected", orgSlug, proj.path, askedRef):
          problem(Http403, "protected_ref", "\"" & askedRef & "\" is a protected ref of the project " & proj.path & ": starting a run on it needs run.start.protected there")
          return
        var qc = newRq(coreRef.rqliteUrl)
        if qc.queueIsFull(if profile.len > 0: profile else: coreRef.profileId):
          problem(Http429, "queue_full", "this organisation has " & $maxUnfinishedRuns & " runs that have not ended; try again when some have")
          return
        # PIP-016: a conductor of the organisation tries the script and the parameters first, if there is one to ask; a certain finding is the author's to fix, anything else the run decides
        var checked = false
        var script = ""
        var source = Source()
        block fromGit:
          if orgSlug.len == 0:
            problem(Http400, "invalid_request", "a script read from a repository belongs to an organisation: give organization")
            return
          let ans = checkSource(namespaceName(orgPrefix, orgShard, orgSlug), fromRepo, given.pairs, currentApiVersion)
          let fp = ans.fetchProblem
          if fp.status != 0 and ans.script.len == 0:
            problem(HttpCode(fp.status), fp.code, fp.message)
            return
          checked = ans.ran
          if ans.problemOf.len > 0:
            problem(Http400, ans.code, ans.message)
            return
          script = ans.script
          source = Source(repository: fromRepo.repository, commit: ans.commit, path: (if fromRepo.path.len == 0: defaultPath else: fromRepo.path), refName: askedRef)
        # D-93: {"approval": true | {"timeout_seconds": n}} makes the run wait for the approvals its project asks for
        var spec = ApprovalSpec()
        if j.hasKey("approval") and j["approval"].kind notin [JNull, JBool] or (j.hasKey("approval") and j["approval"].kind == JBool and j["approval"].getBool):
          var secs = defaultApprovalSeconds
          if j["approval"].kind == JObject and j["approval"].hasKey("timeout_seconds"):
            if j["approval"]["timeout_seconds"].kind != JInt or j["approval"]["timeout_seconds"].getBiggestInt < minApprovalSeconds or j["approval"]["timeout_seconds"].getBiggestInt > maxApprovalSeconds:
              problem(Http400, "invalid_request", "approval.timeout_seconds is between " & $minApprovalSeconds & " and " & $maxApprovalSeconds)
              return
            secs = j["approval"]["timeout_seconds"].getBiggestInt
          elif j["approval"].kind notin [JObject, JBool]:
            problem(Http400, "invalid_request", "approval is true or {\"timeout_seconds\": n}")
            return
          spec = ApprovalSpec(required: gq.requiredApprovals(groupId), timeoutSeconds: secs)
        let id = coreRef.createRun(script, tenant, profile, given.pairs, groupId = groupId, source = source, actor = actorOf(who), approval = spec)
        var made = %*{"id": id, "organization": orgSlug, "project": proj.path, "state": coreRef.stateOfRun(id), "checked": checked}
        if source.repository.len > 0: made["source"] = %*{"repository": source.repository, "commit": source.commit, "path": source.path, "ref": source.refName}
        jsonOk(Http201, made)
      elif meth == "GET" and rest.endsWith("/log") and "/steps/" notin rest:
        # D-77: the log of the whole run, one window: `from=<cursor>` the lines after it, `until=<cursor>` the lines before it, neither the last ones of the run; `limit` at most 500
        let runId = rest[0 ..< rest.len - "/log".len]
        var wantCursor, backwards = true
        var cursor: RunCursor
        var limit = -1
        var seenFrom, seenUntil = false
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            if k == "from" or k == "until":
              let pc = parseCursor(v)
              if not pc.ok:
                problem(Http400, "invalid_request", k & " is <step>.<attempt>.<line>")
                return
              cursor = pc.c
              if k == "from": seenFrom = true else: seenUntil = true
            elif k == "limit":
              try: limit = parseInt(v)
              except ValueError:
                problem(Http400, "invalid_request", "limit must be an integer")
                return
        if seenFrom and seenUntil:
          problem(Http400, "invalid_request", "from and until are not asked together")
          return
        wantCursor = seenFrom or seenUntil
        backwards = not seenFrom
        if not who.admin:
          let owner = coreRef.getRun(runId)
          if owner == nil or not who.mayUseRun(owner):
            problem(Http404, "not_found", "no such run")
            return
        let log = coreRef.getRunLog(runId, wantCursor, cursor, backwards, (if limit < 1: defaultRunWindow else: limit))
        if log == nil:
          problem(Http404, "not_found", "no such run")
          return
        jsonOk(Http200, log)
      elif meth == "GET" and "/steps/" in rest and rest.endsWith("/log"):
        let parts = rest.split("/steps/", maxsplit = 1)
        let seq = try: parseInt(parts[1][0 ..< parts[1].len - "/log".len]) except ValueError: -1
        if parts[0].len == 0 or seq < 0:
          problem(Http400, "invalid_request", "bad step log path")
          return
        # DAT-007: `from` (a line number) and `limit` (at most 500) choose the window; `next` in the answer is where to continue
        var fromLine, limit = -1
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            try:
              if k == "from": fromLine = parseInt(v)
              if k == "limit": limit = parseInt(v)
            except ValueError:
              problem(Http400, "invalid_request", k & " must be an integer")
              return
        if not who.admin:
          let owner = coreRef.getRun(parts[0])
          if owner == nil or not who.mayUseRun(owner):
            problem(Http404, "not_found", "no log stream for this step yet")      # not 403: another organisation's runs are not even confirmed
            return
        let log = coreRef.getStepLog(parts[0], seq, max(0, fromLine), (if limit < 1: maxWindow else: limit))
        if log == nil:
          problem(Http404, "not_found", "no log stream for this step yet")
          return
        jsonOk(Http200, log)
      elif meth == "GET" and "/artifacts" in rest:
        # the artifacts of a run (DAT-003): the list, or one file (read from the store by the core and passed on, up to 64 MiB)
        let parts = rest.split("/artifacts", maxsplit = 1)
        let owner = coreRef.getRun(parts[0])
        if owner == nil or not who.mayUseRun(owner):
          problem(Http404, "not_found", "no such run")
          return
        var c = newRq(coreRef.rqliteUrl)
        let tail = parts[1].strip(chars = {'/'})
        if tail.len == 0:
          jsonOk(Http200, %*{"run_id": parts[0], "artifacts": c.listArtifacts(parts[0])})
          return
        let wanted = c.storedArtifact(parts[0], tail)
        if not wanted.found:
          problem(Http404, "not_found", "this run has no artifact " & tail)
          return
        if wanted.size > maxDownloadBytes:
          problem(Http413, "too_big", "the artifact is bigger than " & $maxDownloadBytes & " bytes; it is read from the store directly")
          return
        let rb = newStoreSet().resolve(wanted.store)
        if rb.be == nil:
          problem(Http503, "store_" & rb.error, "the object store is not ready: " & rb.error)
          return
        # read from the store in blocks and passed on (the API answers with a string, so what is read is held: that is why the limit is small)
        let be = rb.be
        var content = newStringOfCap(int(wanted.size))
        var offset = 0'i64
        while offset < wanted.size:
          let part = be.readRange(wanted.key, offset, min(int64(readSize), wanted.size - offset))
          if not part.res.ok:
            problem(Http502, "storage_unreachable", part.res.error)
            return
          content.add part.data
          offset += part.data.len
          if part.data.len == 0: break
        reply(Http200, content, ["Content-Type: application/octet-stream", "X-Artifact-Sha256: " & wanted.sha256])
      elif meth == "POST" and rest.endsWith(":abort"):
        # RUN-006: stop a run. The same people that may read it: another organisation's run is not confirmed (404), as for a read
        let runId = rest[0 ..< rest.len - ":abort".len]
        let owner = coreRef.getRun(runId)
        if owner == nil or not who.mayUseRun(owner):
          problem(Http404, "not_found", "no such run")
          return
        var cc = newRq(coreRef.rqliteUrl)
        let done = cc.abortRun(runId, getTime().toUnix())
        case done.outcome
        of coNotFound: problem(Http404, "not_found", "no such run")
        of coAlreadyFinished: problem(Http409, "run_finished", "the run has ended already (" & done.state & ")")
        of coAborted:
          cc.record(getTime().toUnix(), actorOf(who), "run.abort", runId, "ok")
          jsonOk(Http200, %*{"id": runId, "state": done.state})
      elif meth == "POST" and (rest.endsWith(":approve") or rest.endsWith(":reject")):
        # D-93: a run that waits for approval is approved or rejected by a person who holds run.approve for it and did not start it; {"comment": "..."} is kept with the answer
        let approving = rest.endsWith(":approve")
        let runId = rest[0 ..< rest.len - (if approving: ":approve".len else: ":reject".len)]
        let owner = coreRef.getRun(runId)
        if owner == nil or not who.mayUseRun(owner):
          problem(Http404, "not_found", "no such run")
          return
        if who.user.len == 0:
          problem(Http403, "forbidden", "a run is approved by a person; a token of an organisation or the operator\'s is not one")
          return
        let aj = try: parseJson(getBody()) except JsonParsingError: nil
        let comment = if aj != nil and aj.kind == JObject and aj.isString("comment"): aj["comment"].getStr.strip[0 ..< min(500, aj["comment"].getStr.strip.len)] else: ""
        var ac = newRq(coreRef.rqliteUrl)
        let ans = ac.answerApproval(runId, who.user, (if approving: "approve" else: "reject"), comment, getTime().toUnix())
        case ans.outcome
        of aoNotFound: problem(Http404, "not_found", "no such run")
        of aoNotWaiting: problem(Http409, "not_waiting_for_approval", "this run does not wait for approval (it is " & ans.state & ")")
        of aoOwnRun: problem(Http403, "own_run", "you started this run: another person approves it")
        of aoAlreadyAnswered: problem(Http409, "already_answered", "you have answered for this run already")
        of aoGiven, aoApproved, aoRejected:
          ac.record(getTime().toUnix(), actorOf(who), (if approving: "run.approve" else: "run.reject"), runId, "ok", comment)
          jsonOk(Http200, %*{"id": runId, "state": ans.state, "approvals": ans.have, "required": ans.required})
      elif meth == "POST" and (rest.endsWith(":hold") or rest.endsWith(":release")):
        # DAT-006: a legal hold on a run - its artifacts and volume are not garbage-collected and its organisation is not deleted for good (core/holds.nim)
        let placing = rest.endsWith(":hold")
        let runId = rest[0 ..< rest.len - (if placing: ":hold".len else: ":release".len)]
        let owner = coreRef.getRun(runId)
        if owner == nil or not who.mayUseRun(owner):
          problem(Http404, "not_found", "no such run")
          return
        var hc = newRq(coreRef.rqliteUrl)
        let orgH = hc.organizationRow(owner{"organization"}.getStr)
        if orgH.id.len == 0:
          problem(Http409, "no_organization", "a hold belongs to an organisation's run; this run belongs to none")
          return
        if placing:
          let hj = try: parseJson(getBody()) except JsonParsingError: nil
          if not hj.isString("reason"):
            problem(Http400, "invalid_request", "{\"reason\": \"...\"} is required: a legal hold has a reason")
            return
          let placed = hc.placeHold(runId, orgH.id, hj["reason"].getStr, actorOf(who), getTime().toUnix())
          if placed.error.len > 0:
            problem(Http400, "invalid_hold", placed.error)
            return
          if placed.placed: hc.record(getTime().toUnix(), actorOf(who), "run.hold", runId, "ok", hj["reason"].getStr[0 ..< min(200, hj["reason"].getStr.len)])
          let h = hc.holdOf(runId)
          jsonOk(if placed.placed: Http201 else: Http200, %*{"id": runId, "held": true, "hold": h.hold.view, "placed": placed.placed})
        else:
          let gone = hc.releaseHold(runId)
          if gone: hc.record(getTime().toUnix(), actorOf(who), "run.release", runId, "ok")
          jsonOk(Http200, %*{"id": runId, "held": false, "released": gone})
      elif meth == "POST" and rest.endsWith(":retry"):
        # PIP-015 failed-only: run again only what failed, in the same run, if its volume is still there (docs/parallel.md section 11)
        let runId = rest[0 ..< rest.len - ":retry".len]
        let owner = coreRef.getRun(runId)
        if owner == nil or not who.mayUseRun(owner):
          problem(Http404, "not_found", "no such run")
          return
        var rc = newRq(coreRef.rqliteUrl)
        let done = rc.retryRun(runId, getTime().toUnix())
        case done.outcome
        of roNotFound: problem(Http404, "not_found", "no such run")
        of roNotRetryable: problem(Http409, "run_not_retryable", "only a run that ended FAILED, INFRASTRUCTURE_ERROR or TIMED_OUT can be run again (this one is " & done.state & ")")
        of roNothingToRetry: problem(Http409, "nothing_to_retry", "no step of this run failed: the script itself ended it, and running it again would end it the same way")
        of roVolumeGone: problem(Http409, "volume_gone", "the volume of this run is gone: start a new run")
        of roRetried:
          rc.record(getTime().toUnix(), actorOf(who), "run.retry", runId, "ok", "steps " & $done.steps)
          jsonOk(Http200, %*{"id": runId, "state": done.state, "retried_steps": done.steps})
      elif meth == "GET" and rest.len == 0:
        # the list of runs (docs/ui.md): ?organization=<slug>&state=<STATE>&limit=<n>&before=<run id>, newest first; a token of an organisation sees its own only
        var askedOrg, askedState, before = ""
        var limit = -1
        if qpos >= 0:
          for k, v in decodeQuery(uri[qpos + 1 .. ^1]):
            case k
            of "organization": askedOrg = v
            of "state": askedState = v
            of "before": before = v
            of "limit":
              try: limit = parseInt(v)
              except ValueError:
                problem(Http400, "invalid_request", "limit must be an integer")
                return
            else: discard
        let scope = runListScope(who, askedOrg)
        if not scope.ok:
          problem(Http403, "forbidden", "this token may list the runs of its own organisation only")
          return
        var c = newRq(coreRef.rqliteUrl)
        jsonOk(Http200, c.listRuns(scope.organization, askedState, limit, before, scope.only, scope.groups, scope.limited, actorOf(who)))
      elif meth == "GET" and rest.len > 0:
        let run = coreRef.getRun(rest)
        if run != nil and not who.mayUseRun(run):
          problem(Http404, "not_found", "no such run")
          return
        if run == nil:
          problem(Http404, "not_found", "no such run")
          return
        # what this caller may do with the run now: its state allows it and the caller's rights allow the call (the UI shows a button for what is true here, and nothing else)
        var ac = newRq(coreRef.rqliteUrl)
        let can = ac.runActions(rest, run{"state"}.getStr)
        # D-93: a person other than the author, who holds run.approve for the run, and has not answered yet
        var answerable = false
        if who.user.len > 0 and run{"approval"} != nil and run["approval"]{"waiting"}.getBool and who.mayInRun("run.approve", run) and run{"started_by"}.getStr != "user:" & who.user:
          answerable = true
          for k in ["approved_by", "rejected_by"]:
            for x in run["approval"][k].getElems:
              if x.getStr == who.user: answerable = false
        run["actions"] = %*{"abort": can.abort and who.mayInRun("run.abort", run), "retry": can.retry and who.mayInRun("run.retry", run),
                             "approve": answerable, "reject": answerable}
        jsonOk(Http200, run)
      else:
        problem(Http404, "not_found", "no such route")
    except Exception as e:
      # not only CatchableError: with -d:ssl std/net lets a plain Exception through the raises inference
      problem(Http500, "internal", e.msg)


var vaultThread: Thread[tuple[rqliteUrl, certs: string, stop: ptr Atomic[bool]]]
var vaultThreadRunning = false

proc joinVault*() =
  if vaultThreadRunning: joinThread(vaultThread)

proc serveApi*(co: Core; port: int) =
  coreRef = co
  createThread(vaultThread, runVaultSetup, (co.rqliteUrl, co.certs, addr stopServers))
  vaultThreadRunning = true
  if authOn:
    # IAM-001: the user `admin` at the first start; the password and the token are written once, in a line that a test can parse. The password has to be changed first.
    var uc = newRq(co.rqliteUrl)
    let legacy = uc.legacyShardBindings()
    if legacy.len > 0:
      var names: seq[string]
      for l in legacy: names.add l.user & ":" & l.role
      stderr.writeLine "core: WARNING - these users have a role at the shard that is not admin, which is no right any more (the shard has no users but its administrators; D-90): " & names[0 ..< min(20, names.len)].join(", ") &
        (if names.len > 20: " and " & $(names.len - 20) & " more" else: "") & ". Give them a role in an organisation (PUT /api/v1/organizations/{slug}/members/{user}) or delete them."
    let made = uc.bootstrapAdminUser(getTime().toUnix())
    if made.len > 0:
      echo "core: FIRST START. The administrator (shown only now): the password is for POST /api/v1/login, the token for 'Authorization: Bearer'; the password has to be changed first,"
      echo "core: PUT /api/v1/users/admin/password {\"current_password\", \"password\"} - until then nothing else is allowed"
      for m in made: echo credentialLine(m)
  if not authOn:
    stderr.writeLine "core: neither CINIM_ADMIN_TOKEN nor CINIM_AUTH=on is set: the API is OPEN, anyone who can reach it may start runs and create organisations (development only)"
  let s = newService(onRequest)      # common/httpsrv.nim: the one way the server is made
  # every thread has a heap of its own that keeps what it has had (about 1 MiB at the first request, more for a big answer): the threads are a value (CINIM_API_THREADS), not a constant
  discard s.start(port, uint(max(2, parseInt(getEnv("CINIM_API_THREADS", "8"))))) 
