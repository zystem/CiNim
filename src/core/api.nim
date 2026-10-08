## REST API of core (9.1): runs (POST /api/v1/runs, GET /api/v1/runs/{id} with the steps' attempts, states and the reason each
## ended the way it did), the bare step-log read (GET /api/v1/runs/{id}/steps/{seq}/log; from/around/search/tail/download are later
## slices, DAT-007), the launch gate, the execution profile's settings (GET/PUT /api/v1/profile, docs/settings.md), the component
## list (/api/v1/components) and Prometheus metrics (/metrics, docs/metrics.md). Bearer tokens (apiauth.nim, IAM-003; OIDC/RBAC are not implemented yet); `project_id`
## and `script` (Lua source) are accepted directly in the body since there is no directory, no repositories and no blob storage yet.
##
## HTTP layer: GuildenStern (D-25): pure Nim, no C dependency. Its `onRequest` is one global dispatcher
## reading thread-local request state via `getUri`/`getMethod`/`getBody`, so routes are matched here, by hand.
import std/[json, os, strutils, uri, times, atomics, tables, httpclient]
import guildenstern/[dispatcher, httpserver]
import scheduler, loggate, logcircuit, retrypolicy, schema, orgrules, routerclient, kubeapi, orgprovision, orgreconcile, logwindow, keptpods, apiauth, stepsecrets, secretvault, vaultsetup, runparams, triggers, objectstore
import ../common/[ctrlauth, envname]
import ../common/rqlite

const base = "/api/v1/runs"
const maxDownloadBytes = 64 * 1024 * 1024

proc problem(status: HttpCode; code, detail: string) =
  reply(status, $(%*{"type": "about:blank", "status": ord(status), "code": code, "detail": detail}),
    ["Content-Type: application/problem+json"])

proc jsonOk(status: HttpCode; body: JsonNode) =
  reply(status, $body, ["Content-Type: application/json"])

let
  orgShard = getEnv("CINIM_SHARD", "001")                  ## the name of this shard: digits only (SHD-001)
  orgPrefix = getEnv("CINIM_NAMESPACE_PREFIX", "cinim")    ## the namespace prefix (SHD-001)
  metricsOn = getEnv("CINIM_METRICS", "true") != "false"   ## the Helm value `metrics.enabled` (SPEC section 15); false makes /metrics a 404

let
  adminToken = getEnv("CINIM_ADMIN_TOKEN")      ## a token of the operator's own (IAM-003); empty: the first start makes one and writes it to the log
  authOn* = adminToken.len > 0 or getEnv("CINIM_AUTH") == "on"     ## otherwise the API is open (development)

proc unauthorized(why: string) =
  reply(Http401, $(%*{"type": "about:blank", "status": 401, "code": "unauthorized", "detail": "a valid API token is required (" & why & ")"}),
    ["Content-Type: application/problem+json", "WWW-Authenticate: Bearer"])

var coreRef: Core   ## set once at startup (main.nim); read-only after that, one HTTP thread pool

let
  kube = inCluster()   ## the Pod's ServiceAccount; not available outside a cluster, and the organisation then is a record only
  provisionOn = kube.available and getEnv("CINIM_PROVISION", "auto") != "off"
  buildOn = getEnv("CINIM_BUILD", "off") == "on"      ## the shard has a build profile: the namespace of every organisation allows build Pods (A.13, D-42)
  bootstrapTtl = parseInt(getEnv("CINIM_CONTROLLER_BOOTSTRAP_TTL", "86400"))   ## seconds a bootstrap token of a controller stays good

proc networkDefaults(): tuple[egress, ingress: string] =
  ## SHD-009: what an organisation gets when it asks for nothing: the chart's `network.egress` (`restricted`, `open`) and `network.ingress`
  ## (`closed`, `open`)
  result.egress = if getEnv("CINIM_NETWORK_EGRESS") == "open": "open" else: "restricted"
  result.ingress = if getEnv("CINIM_NETWORK_INGRESS") == "open": "open" else: "closed"

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
  var buildInternet: JsonNode
  try:
    let raw = getEnv("CINIM_BUILD_INTERNET")
    if raw.len > 0 and raw != "off": buildInternet = parseJson(raw)
  except JsonParsingError:
    discard
  let nd = networkDefaults()
  ProvisionConfig(prefix: orgPrefix, shard: orgShard, shardNamespace: ownNamespace(), buildInternet: buildInternet,
                  egressOpen: (if egress.len > 0: egress else: nd.egress) == "open", ingressOpen: (if ingress.len > 0: ingress else: nd.ingress) == "open",
                  build: buildOn, buildEgress: buildEgress, buildCaps: getEnv("CINIM_BUILD_CAPS"), buildMemoryLimit: getEnv("CINIM_BUILD_MEMORY_LIMIT"),
                  stepEphemeralLimit: getEnv("CINIM_STEP_EPHEMERAL_LIMIT"), buildEphemeralLimit: getEnv("CINIM_BUILD_EPHEMERAL_LIMIT"),
                  buildSeccomp: getEnv("CINIM_BUILD_SECCOMP"), buildIngress: buildIngress,
                  controllerImage: getEnv("CINIM_CONTROLLER_IMAGE"), stateClass: getEnv("CINIM_CONTROLLER_STATE_CLASS"),
                  multi: cfg.url.len > 0, host: pub.hostname, basePath: pub.path,
                  ingressClass: getEnv("CINIM_INGRESS_CLASS"), tlsSecret: getEnv("CINIM_INGRESS_TLS_SECRET"), annotations: annotations)

proc reconcileEnv(co: Core): PassEnv =
  ## SHD-008: what a pass needs; the settings are the Helm values `organizations.reconcileInterval` and `organizations.retention`
  PassEnv(rqliteUrl: co.rqliteUrl, certs: co.certs, bootstrapTtl: bootstrapTtl,
          mk: proc (egress, ingress: string): ProvisionConfig {.gcsafe.} =
            {.cast(gcsafe).}: provisionConfig(currentConfig(), egress, ingress),
          interval: max(10, parseInt(getEnv("CINIM_ORG_RECONCILE_INTERVAL", "300"))),
          retention: parseBiggestInt(getEnv("CINIM_ORG_RETENTION", $(14 * 86400))))

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
          problem(Http409, fired.reason, "no run was started: " & fired.reason)
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
          jsonOk(Http200, %*{"id": made.id, "token": made.token, "replaced": who.id})
          return
        if who.mustChange:
          problem(Http403, "token_change_required", "this is the first token of the shard: change it first, POST /api/v1/token:rotate answers with a new one and revokes this one")
          return
        if not who.admin and not path.startsWith(base):
          problem(Http403, "forbidden", "this token is for the runs of one organisation only")
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
          jsonOk(Http201, %*{"id": made.id, "token": made.token, "name": name, "scope": j["scope"].getStr, "expires_at": (if ttl > 0: now + ttl else: 0)})
        elif tmeth == "GET" and path == "/api/v1/tokens":
          jsonOk(Http200, %*{"tokens": c.listApiTokens()})
        elif tmeth == "DELETE" and path.startsWith("/api/v1/tokens/"):
          let id = path["/api/v1/tokens/".len .. ^1]
          if not c.revokeApiToken(id, getTime().toUnix()):
            problem(Http404, "not_found", "no such token, or it is revoked already")
            return
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
            problem(Http400, "invalid_request", "a JSON object with any of infra_retries, log_max_bytes, log_spool_bytes, log_hold_timeout, liveness_timeout is required")
            return
          let cur = coreRef.getProfileSettings(profileId)
          var s = ProfileSettings(infraRetries: cur["infra_retries"].getInt, logMaxBytes: cur["log_max_bytes"].getBiggestInt,
                                  livenessTimeout: cur["liveness_timeout"].getInt, logSpoolBytes: cur["log_spool_bytes"].getBiggestInt,
                                  logHoldTimeout: cur["log_hold_timeout"].getInt)
          for k in ["infra_retries", "log_max_bytes", "liveness_timeout", "log_spool_bytes", "log_hold_timeout"]:
            if j.hasKey(k) and j[k].kind != JInt:
              problem(Http400, "invalid_request", k & " must be an integer")
              return
          if j.hasKey("infra_retries"): s.infraRetries = j["infra_retries"].getInt
          if j.hasKey("log_max_bytes"): s.logMaxBytes = j["log_max_bytes"].getBiggestInt
          if j.hasKey("liveness_timeout"): s.livenessTimeout = j["liveness_timeout"].getInt
          if j.hasKey("log_spool_bytes"): s.logSpoolBytes = j["log_spool_bytes"].getBiggestInt
          if j.hasKey("log_hold_timeout"): s.logHoldTimeout = j["log_hold_timeout"].getInt
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
      if path == "/api/v1/storage" or path == "/api/v1/storage:check":
        # the object store of the shard (core/objectstore.nim): an administrator's calls; the secret is sealed in the database and never answered
        var c = newRq(coreRef.rqliteUrl)
        let smeth = getMethod()
        if path == "/api/v1/storage:check":
          if smeth != "POST":
            problem(Http405, "method_not_allowed", "POST")
            return
          let st = c.loadStore()
          if not st.ok:
            problem(if st.retry: Http503 else: Http409, "store_" & st.error, "the object store is not ready: " & st.error)
            return
          let bad = st.roundTrip()
          if bad.len > 0: problem(Http502, "storage_unreachable", bad)
          else: jsonOk(Http200, %*{"ok": true, "endpoint": st.cfg.endpoint, "bucket": st.cfg.bucket})
        elif smeth == "GET":
          let cfg = c.loadConfig()
          jsonOk(Http200, %*{"configured": cfg.found, "endpoint": cfg.endpoint, "region": cfg.region, "bucket": cfg.bucket, "access_key_id": cfg.keyId})
        elif smeth == "DELETE":
          jsonOk(Http200, %*{"deleted": c.forgetStore()})
        elif smeth == "PUT":
          let j = try: parseJson(getBody()) except JsonParsingError: nil
          if j == nil or j.kind != JObject:
            problem(Http400, "invalid_request", "the body is {endpoint, region, bucket, access_key_id, secret_access_key}")
            return
          let cfg = StoreConfig(found: true, endpoint: j{"endpoint"}.getStr, region: j{"region"}.getStr("garage"), bucket: j{"bucket"}.getStr, keyId: j{"access_key_id"}.getStr)
          let secret = j{"secret_access_key"}.getStr
          let why = checkConfig(cfg, secret)
          if why.len > 0:
            problem(Http400, "invalid_request", why)
            return
          let vk = vaultKek()
          if not vk.ready:
            reply(Http503, $(%*{"type": "about:blank", "status": 503, "code": "secrets_unavailable", "detail": vaultError()}),
                  ["Content-Type: application/problem+json", "Retry-After: 15"])
            return
          # the settings are tried before they are kept: a store that does not take an object is not one to write down
          let bad = roundTrip(Store(ok: true, cfg: cfg, secret: secret))
          if bad.len > 0:
            problem(Http400, "storage_unreachable", bad)
            return
          let saved = c.saveStore(vk.kek, cfg, secret, getTime().toUnix())
          if not saved.ok:
            problem(if saved.retry: Http503 else: Http500, "secrets_error", saved.error)
            return
          jsonOk(Http200, %*{"configured": true, "endpoint": cfg.endpoint, "region": cfg.region, "bucket": cfg.bucket, "access_key_id": cfg.keyId, "checked": true})
        else:
          problem(Http405, "method_not_allowed", "GET, PUT, DELETE, or POST :check")
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
            let made = c.createTrigger(org.id, spec.spec, getTime().toUnix())
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
            problem(Http409, fired.reason, "no run was started: " & fired.reason)
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
          jsonOk(Http200, %*{"organization": slug, "name": secName, "version": put.version})
        elif smeth == "DELETE":
          if not c.forgetStepSecret(org.id, secName):
            problem(Http404, "not_found", "no such secret")
            return
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
      if not path.startsWith(base):
        problem(Http404, "not_found", "no such route")
        return
      let rest = path[base.len .. ^1].strip(chars = {'/'})
      let meth = getMethod()
      if meth == "POST" and rest == "":
        let j = try: parseJson(getBody()) except JsonParsingError: nil
        if j == nil or not j.hasKey("project_id") or not j.hasKey("script"):
          problem(Http400, "invalid_request", "project_id and script are required")
          return
        # SHD-007: a run belongs to an organisation, whose execution profile places its steps in the organisation's namespace.
        # Without `organization` it belongs to the shard's default tenant and profile (single-tenant setups, development).
        if not who.admin and (not j.hasKey("organization") or j["organization"].getStr != who.org):
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
        let id = coreRef.createRun(j["project_id"].getStr, j["script"].getStr, tenant, profile, given.pairs)
        jsonOk(Http201, %*{"id": id, "organization": orgSlug, "state": "RUNNING"})
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
        let st = c.loadStore()
        if not st.ok:
          problem(Http503, "store_" & st.error, "the object store is not ready: " & st.error)
          return
        let cl = newHttpClient(timeout = 60000)
        defer: cl.close()
        let got = cl.request(st.url("GET", wanted.key, getExpires), httpMethod = HttpGet)
        if got.code.int div 100 != 2:
          problem(Http502, "storage_unreachable", "the store answered " & $got.code)
          return
        reply(Http200, got.body, ["Content-Type: application/octet-stream", "X-Artifact-Sha256: " & wanted.sha256])
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
  if authOn and adminToken.len == 0:
    # the first start: the first administrator token, once, in the log (as TeamCity writes its super user token); it has to be changed at first use
    var c = newRq(co.rqliteUrl)
    let first = c.bootstrapAdminToken(getTime().toUnix())
    if first.len > 0:
      echo "core: FIRST START. The administrator's API token (shown only now): ", first
      echo "core: it works for one thing, to be changed: POST /api/v1/token:rotate with 'Authorization: Bearer <this token>' answers with a new one"
  elif not authOn:
    stderr.writeLine "core: neither CINIM_ADMIN_TOKEN nor CINIM_AUTH=on is set: the API is OPEN, anyone who can reach it may start runs and create organisations (development only)"
  let s = newHttpServer(onRequest)
  s.start(port, 64)
