## REST API of core (9.1): runs (POST /api/v1/runs, GET /api/v1/runs/{id} with the steps' attempts, states and the reason each
## ended the way it did), the bare step-log read (GET /api/v1/runs/{id}/steps/{seq}/log; from/around/search/tail/download are later
## slices, DAT-007), the launch gate, the execution profile's settings (GET/PUT /api/v1/profile, docs/settings.md), the component
## list (/api/v1/components) and Prometheus metrics (/metrics, docs/metrics.md). Bearer tokens (apiauth.nim, IAM-003; OIDC/RBAC are not implemented yet); `group`
## and `script` (Lua source) are accepted directly in the body since there is no directory, no repositories and no blob storage yet.
##
## HTTP layer: GuildenStern (D-25): pure Nim, no C dependency. Its `onRequest` is one global dispatcher
## reading thread-local request state via `getUri`/`getMethod`/`getBody`, so routes are matched here, by hand.
import std/[json, os, strutils, uri, times, atomics, tables, httpclient, options]
import ../common/httpsrv
import audit, joblocks, orgvars, pwcheck, runstorage, scheduler, loggate, logcircuit, retrypolicy, schema, orgrules, routerclient, kubeapi, orgprovision, orgreconcile, logwindow, keptpods, apiauth, stepsecrets, secretvault, vaultsetup, runparams, triggers, objectstore, groups, holds, cachestore, varaudit, preflight
import ../common/[ctrlauth, envname, luaapi]
import ../common/rqlite

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
  let nd = networkDefaults()
  ProvisionConfig(prefix: orgPrefix, shard: orgShard, shardNamespace: ownNamespace(), buildInternet: buildInternet,
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
        # the probes of the Pod: alive, and says nothing else, so that it needs no token
        jsonOk(Http200, %*{"status": "ok"})
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
          problem(Http400, "invalid_request", "the body is empty or {\"params\": {...}}")
          return
        let given = checkParams(bj{"params"})
        if given.error.len > 0:
          problem(Http400, "invalid_params", given.error)
          return
        let fired = coreRef.fire(hook.row, given.pairs, getTime().toUnix())
        if fired.started:
          jsonOk(Http201, %*{"id": fired.runId, "organization": hook.row.slug, "trigger_id": hook.row.id, "state": "RUNNING"})
        else:
          problem((if fired.reason == "queue_full": Http429 else: Http409), fired.reason, "no run was started: " & fired.reason)
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
        let loginName = lj["user"].getStr
        # too many wrong passwords for this name, or for all names together, and nobody is let in for a while (the audit is what is counted)
        let wait = lc.loginRetryAfter(loginName, now)
        if wait.blocked:
          lc.record(now, "login", "login", loginName, "throttled", "retry after " & $wait.seconds & " s")
          reply(Http429, $(%*{"type": "about:blank", "status": 429, "code": "too_many_attempts",
                              "detail": "too many wrong passwords; try again in " & $wait.seconds & " seconds"}),
                ["Content-Type: application/problem+json", "Retry-After: " & $wait.seconds])
          return
        let li = lc.login(loginName, lj["password"].getStr, now)
        if not li.ok:
          lc.record(now, "login", "login", loginName, "failed")
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
        if who.mustChange and not selfService(who.user, getMethod(), path):
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
        if not who.admin:
          if who.roles.len > 0:
            # IAM-001: the roles of the user (rw, dev, ro) are the shard's, and every organisation inherits them; what each may do is in rbac.nim
            if not rolesMay(who.roles, getMethod(), path) and not selfService(who.user, getMethod(), path):
              ac.record(getTime().toUnix(), actorOf(who), "access", getMethod() & " " & path, "denied", "roles " & who.roles.join(","))
              problem(Http403, "forbidden", "the role of " & who.user & " (" & who.roles.join(", ") & ") does not allow " & getMethod() & " " & path)
              return
          elif not path.startsWith(base):
            problem(Http403, "forbidden", "this token is for the runs of one organisation only")
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
          if not validRole(nj["role"].getStr):
            problem(Http400, "invalid_request", "role is one of " & shardRoles.join(", "))
            return
          let lenBad = passwordProblem(nj["password"].getStr)
          if lenBad.len > 0:
            problem(Http400, "invalid_password", lenBad)
            return
          let nv = checkPassword(pwnedCfg, nj["password"].getStr)
          if nv.problem.len > 0:
            problem(Http400, nv.code, nv.problem)
            return
          if not uc.createUser(name, nj["role"].getStr, nj["password"].getStr, getTime().toUnix()):
            problem(Http409, "user_exists", "there is a user " & name & " already")
            return
          uc.record(getTime().toUnix(), actorOf(who), "user.create", name, "ok", "role " & nj["role"].getStr)
          jsonOk(Http201, %*{"name": name, "role": nj["role"].getStr, "scope": shardScope, "breach_check": nv.breachCheck})
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
      if path == "/api/v1/roles":
        # IAM-001: the roles of the shard, which every organisation inherits (administrator)
        if getMethod() != "GET":
          problem(Http405, "method_not_allowed", "GET")
          return
        var rc = newRq(coreRef.rqliteUrl)
        jsonOk(Http200, %*{"roles": rc.listRoles()})
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
          for o in c.listOrganizationRows():
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
            # the identity of the namespace's controller (IAM-003): a generation in the database, the token made from it; asking
            # again after a failure finds the same row and makes the same token
            let pc = provisionConfig(cfg, netEgress, netIngress)
            let ns = orgNamespace(pc, slug)
            c.ensureCredentialRow(ns, getTime().toUnix() + bootstrapTtl)
            let master = coreSecret(coreRef.certs)
            let token = bootstrapToken(master, ns, c.credentialRow(ns).generation)
            let r = provision(kube, pc, slug, loadCurve(coreRef.certs), token)
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
          if provisionOn: c.setControllerSpec(slug, controllerSpecHash(netNow, slug))       # the reconciliation then leaves this controller alone until the settings change
          jsonOk(Http201, %*{"id": id, "slug": slug, "name": j{"name"}.getStr, "namespace": namespaceName(orgPrefix, orgShard, slug),
                             "url": orgUrl(cfg.publicBase, slug), "provisioned": provisionOn,
                             "network": {"egress": (if egressNow: "open" else: "restricted"), "ingress": (if ingressNow: "open" else: "closed")}, "kubernetes": provisioned,
                             "checked_against_router": view.configured and view.fetchedAt > 0})
        else:
          problem(Http405, "method_not_allowed", "GET or POST")
        return
      if path.startsWith("/api/v1/organizations/") and path.endsWith(":rotate-controller-credential"):
        # IAM-003: a new generation of the identity of the organisation's controller, for the case that its state volume is lost or
        # its credential leaked; the old credential stops working at once and the controller enrols again with a new bootstrap token
        if getMethod() != "POST":
          problem(Http405, "method_not_allowed", "POST")
          return
        let slug = path["/api/v1/organizations/".len ..< path.len - ":rotate-controller-credential".len]
        var c = newRq(coreRef.rqliteUrl)
        if c.organizationState(slug).len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slug)
          return
        let pc = provisionConfig(currentConfig())
        let ns = orgNamespace(pc, slug)
        if not c.credentialRow(ns).found:
          problem(Http409, "no_controller_identity", "this organisation has no controller identity (it was made without a cluster)")
          return
        var kubernetes = newJObject()
        c.rotateCredential(ns, getTime().toUnix() + bootstrapTtl)
        let rotated = %*[{"namespace": ns, "generation": c.credentialRow(ns).generation}]
        if provisionOn:
          let r = renewBootstrapSecret(kube, pc, slug, bootstrapToken(coreSecret(coreRef.certs), ns, c.credentialRow(ns).generation))
          if not r.ok:
            reply(Http502, $(%*{"type": "about:blank", "status": 502, "code": "rotate_failed", "step": r.failedStep, "detail": r.error}),
                  ["Content-Type: application/problem+json"])
            return
          kubernetes[ns] = stepsJson(r)
        jsonOk(Http200, %*{"slug": slug, "namespace": ns, "generation": c.credentialRow(ns).generation, "rotated": rotated, "kubernetes": kubernetes})
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
      if path.startsWith("/api/v1/organizations/") and "/groups" in path:
        # PRJ-001, D-54: the groups of an organisation, nested up to 8 levels, and their variables (inherited by the groups below and by the runs in them).
        #   GET /groups                      the groups, by path
        #   PUT|GET|DELETE /groups/{path}    make (the parent has to exist), show, remove (only an empty one) the group at a path such as team/backend
        #   /groups/{path}/variables[/NAME]  the variables of the group
        let restG = path["/api/v1/organizations/".len .. ^1]
        let slugG = restG.split("/groups")[0]
        let afterG = restG[slugG.len .. ^1]            # "/groups", "/groups/a/b", "/groups/a/b/variables/NAME"
        if slugG.len == 0 or not (afterG == "/groups" or afterG.startsWith("/groups/")):
          problem(Http404, "not_found", "no such route")
          return
        var gc = newRq(coreRef.rqliteUrl)
        let orgG = gc.organizationRow(slugG)
        if orgG.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slugG)
          return
        let gpath = afterG["/groups".len .. ^1].strip(chars = {'/'})
        let gmeth = getMethod()
        if gpath.len == 0:
          if gmeth != "GET":
            problem(Http405, "method_not_allowed", "GET lists the groups; PUT /groups/{path} makes one")
            return
          var items = newJArray()
          for g in gc.listGroups(orgG.id): items.add %*{"path": g.path, "depth": g.depth}
          jsonOk(Http200, %*{"organization": slugG, "groups": items})
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
              problem(Http400, "invalid_request", "a JSON object with cache_quota_bytes and/or cache_retention_days is required")
              return
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
            gc.setGroupLimit(sg.id, q, d)
          elif gmeth != "GET":
            problem(Http405, "method_not_allowed", "GET or PUT")
            return
          let lim = gc.groupLimit(sg.id)
          jsonOk(Http200, %*{"organization": slugG, "group": normalPath(sp), "cache_quota_bytes": lim.quota, "cache_retention_days": lim.retentionDays,
                             "effective_cache_retention_seconds": gc.retentionSeconds(orgG.id, sg.id, cacheRetentionFromEnv())})
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
          jsonOk(Http200, %*{"organization": slugG, "group": normalPath(groupPath)})
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
            for t in c.listTriggers(org.id): items.add t.view
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
            let tg = c.groupIdOf(org.id, spec.spec.groupPath)
            if not tg.found:
              problem(Http404, "group_not_found", "the organisation " & slug & " has no group " & spec.spec.groupPath)
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
        if not found.found:
          problem(Http404, "not_found", "no such trigger")
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
          let fired = coreRef.fire(found.row, given.pairs, getTime().toUnix())
          if fired.started:
            jsonOk(Http201, %*{"id": fired.runId, "organization": slug, "trigger_id": tid, "state": "RUNNING"})
          else:
            problem((if fired.reason == "queue_full": Http429 else: Http409), fired.reason, "no run was started: " & fired.reason)
        else:
          problem(Http405, "method_not_allowed", "GET, DELETE, or POST :enable :disable :rotate-secret :fire")
        return
      if path.startsWith("/api/v1/organizations/") and "/secrets" in path:
        # the secrets of an organisation that its steps may ask for (core/stepsecrets.nim): names and versions are in the database, the values only in
        # Kubernetes Secrets of the organisation's namespace. An administrator's call; the value is read from the body and is not logged or answered.
        let rest = path["/api/v1/organizations/".len .. ^1]
        let parts = rest.split("/secrets")
        let slug = parts[0]
        let secName = if parts.len > 1: parts[1].strip(chars = {'/'}) else: ""
        if parts.len != 2 or (parts[1].len > 0 and not parts[1].startsWith("/")) or slug.len == 0:
          problem(Http404, "not_found", "no such route")
          return
        var c = newRq(coreRef.rqliteUrl)
        let org = c.organizationRow(slug)
        if org.id.len == 0:
          problem(Http404, "organization_not_found", "this shard has no organisation " & slug)
          return
        let smeth = getMethod()
        if smeth == "GET" and secName.len == 0:
          jsonOk(Http200, %*{"organization": slug, "secrets": c.listStepSecrets(org.id)})
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
          let put = c.putSecret(vk.kek, org.id, secName, value, getTime().toUnix())
          if not put.ok:
            if put.retry:
              reply(Http503, $(%*{"type": "about:blank", "status": 503, "code": "secrets_unavailable", "detail": put.error}),
                    ["Content-Type: application/problem+json", "Retry-After: 15"])
            else:
              problem(Http500, "secrets_error", put.error)
            return
          c.recordSecret(c.variableAuditMode(org.id), coreSecret(coreRef.certs), org.id, getTime().toUnix(), who, slug, secName, put.version, some(value))
          jsonOk(Http200, %*{"organization": slug, "name": secName, "version": put.version})
        elif smeth == "DELETE":
          if not c.forgetStepSecret(org.id, secName):
            problem(Http404, "not_found", "no such secret")
            return
          c.recordSecret(c.variableAuditMode(org.id), coreSecret(coreRef.certs), org.id, getTime().toUnix(), who, slug, secName, 0, none(string))
          jsonOk(Http200, %*{"organization": slug, "name": secName, "deleted": true})
        else:
          problem(Http405, "method_not_allowed", "PUT or DELETE")
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
        if pj == nil or pj.kind != JObject or not pj.isString("script") or not pj.isString("organization"):
          problem(Http400, "invalid_request", "{\"organization\": \"...\", \"script\": \"...\", \"params\": {...}} is required")
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
        jsonOk(Http200, checkScript(namespaceName(orgPrefix, orgShard, slugP), pj["script"].getStr, givenP.pairs, currentApiVersion).view)
        return
      if not path.startsWith(base):
        problem(Http404, "not_found", "no such route")
        return
      let rest = path[base.len .. ^1].strip(chars = {'/'})
      let meth = getMethod()
      if meth == "POST" and rest == "":
        let j = try: parseJson(getBody()) except JsonParsingError: nil
        if j == nil or not j.hasKey("script"):
          problem(Http400, "invalid_request", "script is required")
          return
        # SHD-007: a run belongs to an organisation, whose execution profile places its steps in the organisation's namespace.
        # Without `organization` it belongs to the shard's default tenant and profile (single-tenant setups, development).
        if not who.acrossOrgs and (not j.hasKey("organization") or j["organization"].getStr != who.org):
          problem(Http403, "forbidden", "this token may start runs of the organisation " & who.org & " only")
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
        # PRJ-001, D-54: the run belongs to a group of the organisation (by its path), or to the organisation itself
        var groupId = ""
        if j.hasKey("group") and not (j["group"].kind == JString and j["group"].getStr.strip(chars = {'/'}).len == 0):
          if j["group"].kind != JString:
            problem(Http400, "invalid_request", "group must be the path of a group, for example team/backend")
            return
          if orgSlug.len == 0:
            problem(Http400, "invalid_request", "a group belongs to an organisation: give organization")
            return
          var gq = newRq(coreRef.rqliteUrl)
          let g = gq.groupIdOf(tenant, j["group"].getStr)
          if not g.found:
            problem(Http404, "group_not_found", "the organisation " & orgSlug & " has no group " & normalPath(j["group"].getStr))
            return
          groupId = g.id
        var qc = newRq(coreRef.rqliteUrl)
        if qc.queueIsFull(if profile.len > 0: profile else: coreRef.profileId):
          problem(Http429, "queue_full", "this organisation has " & $maxUnfinishedRuns & " runs that have not ended; try again when some have")
          return
        # PIP-016: a conductor of the organisation tries the script and the parameters first, if there is one to ask; a certain finding is the author's to fix, anything else the run decides
        var checked = false
        if orgSlug.len > 0:
          let chk = checkScript(namespaceName(orgPrefix, orgShard, orgSlug), j["script"].getStr, given.pairs, currentApiVersion)
          checked = chk.ran
          if chk.problemOf.len > 0:
            problem(Http400, chk.code, chk.message)
            return
        let id = coreRef.createRun(j["script"].getStr, tenant, profile, given.pairs, groupId = groupId)
        jsonOk(Http201, %*{"id": id, "organization": orgSlug, "state": "RUNNING", "checked": checked})
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
          if owner == nil or not who.mayUseOrg(owner{"organization"}.getStr):
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
        if owner == nil or not who.mayUseOrg(owner{"organization"}.getStr):
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
      elif meth == "POST" and rest.endsWith(":cancel"):
        # RUN-006: stop a run. The same people that may read it: another organisation's run is not confirmed (404), as for a read
        let runId = rest[0 ..< rest.len - ":cancel".len]
        let owner = coreRef.getRun(runId)
        if owner == nil or not who.mayUseOrg(owner{"organization"}.getStr):
          problem(Http404, "not_found", "no such run")
          return
        var cc = newRq(coreRef.rqliteUrl)
        let done = cc.cancelRun(runId, getTime().toUnix())
        case done.outcome
        of coNotFound: problem(Http404, "not_found", "no such run")
        of coAlreadyFinished: problem(Http409, "run_finished", "the run has ended already (" & done.state & ")")
        of coCanceled:
          cc.record(getTime().toUnix(), actorOf(who), "run.cancel", runId, "ok")
          jsonOk(Http200, %*{"id": runId, "state": done.state})
      elif meth == "POST" and (rest.endsWith(":hold") or rest.endsWith(":release")):
        # DAT-006: a legal hold on a run - its artifacts and volume are not garbage-collected and its organisation is not deleted for good (core/holds.nim)
        let placing = rest.endsWith(":hold")
        let runId = rest[0 ..< rest.len - (if placing: ":hold".len else: ":release".len)]
        let owner = coreRef.getRun(runId)
        if owner == nil or not who.mayUseOrg(owner{"organization"}.getStr):
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
        if owner == nil or not who.mayUseOrg(owner{"organization"}.getStr):
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
      elif meth == "GET" and rest.len > 0:
        let run = coreRef.getRun(rest)
        if run != nil and not who.mayUseOrg(run{"organization"}.getStr):
          problem(Http404, "not_found", "no such run")
          return
        if run == nil:
          problem(Http404, "not_found", "no such run")
          return
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
