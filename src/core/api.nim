## REST API of core (9.1): runs (POST /api/v1/runs, GET /api/v1/runs/{id} with the steps' attempts, states and the reason each
## ended the way it did), the bare step-log read (GET /api/v1/runs/{id}/steps/{seq}/log; from/around/search/tail/download are later
## slices, DAT-007), the launch gate, the execution profile's settings (GET/PUT /api/v1/profile, docs/settings.md), the component
## list (/api/v1/components) and Prometheus metrics (/metrics, docs/metrics.md). No auth yet (OIDC/RBAC are not implemented yet); `project_id`
## and `script` (Lua source) are accepted directly in the body since there is no directory, no repositories and no blob storage yet.
##
## HTTP layer: GuildenStern (D-25): pure Nim, no C dependency. Its `onRequest` is one global dispatcher
## reading thread-local request state via `getUri`/`getMethod`/`getBody`, so routes are matched here, by hand.
import std/[json, strutils]
import guildenstern/[dispatcher, httpserver]
import scheduler, loggate, logcircuit, retrypolicy

const base = "/api/v1/runs"

proc problem(status: HttpCode; code, detail: string) =
  reply(status, $(%*{"type": "about:blank", "status": ord(status), "code": code, "detail": detail}),
    ["Content-Type: application/problem+json"])

proc jsonOk(status: HttpCode; body: JsonNode) =
  reply(status, $body, ["Content-Type: application/json"])

var coreRef: Core   ## set once at startup (main.nim); read-only after that, one HTTP thread pool

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
        if getMethod() == "GET":
          jsonOk(Http200, coreRef.getProfileSettings())
        elif getMethod() == "PUT":
          let j = try: parseJson(getBody()) except JsonParsingError: nil
          if j == nil or j.kind != JObject:
            problem(Http400, "invalid_request", "a JSON object with any of infra_retries, log_max_bytes, log_spool_bytes, log_hold_timeout, liveness_timeout is required")
            return
          let cur = coreRef.getProfileSettings()
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
          coreRef.setProfileSettings(s)
          jsonOk(Http200, coreRef.getProfileSettings())
        else:
          problem(Http405, "method_not_allowed", "GET or PUT")
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
        let id = coreRef.createRun(j["project_id"].getStr, j["script"].getStr)
        jsonOk(Http201, %*{"id": id, "state": "RUNNING"})
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
    except CatchableError as e:
      problem(Http500, "internal", e.msg)

proc serveApi*(co: Core; port: int) =
  coreRef = co
  let s = newHttpServer(onRequest)
  s.start(port, 64)
