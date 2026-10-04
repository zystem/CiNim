## REST API of core (9.1): runs (POST /api/v1/runs, GET /api/v1/runs/{id} with the steps' attempts, states and the reason each
## ended the way it did), the bare step-log read (GET /api/v1/runs/{id}/steps/{seq}/log; from/around/search/tail/download are later
## slices, DAT-007), the launch gate, the execution profile's settings (GET/PUT /api/v1/profile, docs/settings.md), the component
## list (/api/v1/components) and Prometheus metrics (/metrics, docs/metrics.md). No auth yet (OIDC/RBAC are not implemented yet); `project_id`
## and `script` (Lua source) are accepted directly in the body since there is no directory, no repositories and no blob storage yet.
##
## HTTP layer: GuildenStern (D-25): pure Nim, no C dependency. Its `onRequest` is one global dispatcher
## reading thread-local request state via `getUri`/`getMethod`/`getBody`, so routes are matched here, by hand.
import std/[json, os, strutils, uri, times]
import guildenstern/[dispatcher, httpserver]
import scheduler, loggate, logcircuit, retrypolicy, schema, orgrules, routerclient, kubeapi, orgprovision
import ../common/rqlite

const base = "/api/v1/runs"

proc problem(status: HttpCode; code, detail: string) =
  reply(status, $(%*{"type": "about:blank", "status": ord(status), "code": code, "detail": detail}),
    ["Content-Type: application/problem+json"])

proc jsonOk(status: HttpCode; body: JsonNode) =
  reply(status, $body, ["Content-Type: application/json"])

let
  orgShard = getEnv("CINIM_SHARD", "001")                  ## the name of this shard: digits only (SHD-001)
  orgPrefix = getEnv("CINIM_NAMESPACE_PREFIX", "cinim")    ## the namespace prefix (SHD-001)
  metricsOn = getEnv("CINIM_METRICS", "true") != "false"   ## the Helm value `metrics.enabled` (SPEC section 15); false makes /metrics a 404

var coreRef: Core   ## set once at startup (main.nim); read-only after that, one HTTP thread pool

let
  kube = inCluster()   ## the Pod's ServiceAccount; not available outside a cluster, and the organisation then is a record only
  provisionOn = kube.available and getEnv("CINIM_PROVISION", "auto") != "off"

proc provisionConfig(cfg: RouterConfig): ProvisionConfig =
  ## SHD-007: what the objects of an organisation are made from. In the `multi` mode (a router is configured) the core also makes
  ## the Ingress <basePath>/<slug>/ of the organisation; the host and the base path are those of the public URL.
  let pub = parseUri(cfg.publicBase)
  var annotations: JsonNode
  try:
    let raw = getEnv("CINIM_INGRESS_ANNOTATIONS")
    if raw.len > 0: annotations = parseJson(raw)
  except JsonParsingError:
    discard
  ProvisionConfig(prefix: orgPrefix, shard: orgShard, shardNamespace: ownNamespace(),
                  controllerImage: getEnv("CINIM_CONTROLLER_IMAGE"), stateClass: getEnv("CINIM_CONTROLLER_STATE_CLASS"),
                  multi: cfg.url.len > 0, host: pub.hostname, basePath: pub.path,
                  ingressClass: getEnv("CINIM_INGRESS_CLASS"), tlsSecret: getEnv("CINIM_INGRESS_TLS_SECRET"), annotations: annotations)

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
            let r = provision(kube, provisionConfig(cfg), slug, loadCurve(coreRef.certs))
            if not r.ok:
              # what was made stays; asking again makes the rest (every create is idempotent)
              reply(Http502, $(%*{"type": "about:blank", "status": 502, "code": "provision_failed", "step": r.failedStep,
                                  "detail": r.error, "done": stepsJson(r)}), ["Content-Type: application/problem+json"])
              return
            provisioned = %*{"steps": stepsJson(r), "skipped": r.skipped}
          let id = try: c.addOrganization(slug, j{"name"}.getStr)
                   except RqError:
                     problem(Http409, "slug_exists", "this shard already has an organisation with that slug")
                     return
          jsonOk(Http201, %*{"id": id, "slug": slug, "name": j{"name"}.getStr, "namespace": namespaceName(orgPrefix, orgShard, slug),
                             "url": orgUrl(cfg.publicBase, slug), "provisioned": provisionOn, "kubernetes": provisioned,
                             "checked_against_router": view.configured and view.fetchedAt > 0})
        else:
          problem(Http405, "method_not_allowed", "GET or POST")
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
        if doPurge: c.deleteOrganization(slug) else: c.setOrganizationState(slug, "disabled")
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
        let id = coreRef.createRun(j["project_id"].getStr, j["script"].getStr, tenant, profile)
        jsonOk(Http201, %*{"id": id, "organization": orgSlug, "state": "RUNNING"})
      elif meth == "GET" and "/steps/" in rest and rest.endsWith("/log"):
        let parts = rest.split("/steps/", maxsplit = 1)
        let seq = try: parseInt(parts[1][0 ..< parts[1].len - "/log".len]) except ValueError: -1
        if parts[0].len == 0 or seq < 0:
          problem(Http400, "invalid_request", "bad step log path")
          return
        let log = coreRef.getStepLog(parts[0], seq)
        if log == nil:
          problem(Http404, "not_found", "no log stream for this step yet")
          return
        jsonOk(Http200, log)
      elif meth == "GET" and rest.len > 0:
        let run = coreRef.getRun(rest)
        if run == nil:
          problem(Http404, "not_found", "no such run")
          return
        jsonOk(Http200, run)
      else:
        problem(Http404, "not_found", "no such route")
    except Exception as e:
      # not only CatchableError: with -d:ssl std/net lets a plain Exception through the raises inference
      problem(Http500, "internal", e.msg)

proc serveApi*(co: Core; port: int) =
  coreRef = co
  let s = newHttpServer(onRequest)
  s.start(port, 64)
