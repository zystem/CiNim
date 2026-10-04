## Shard rqlite schema, the implemented subset (spec 8.2): `runs`, `run_journal`, `jobs`, `steps` (with the attempt, the Lua options
## and the shim's last state: shim_*, D-29), `job_controllers`, `leases`, `execution_profiles` (the settings of docs/settings.md)
## plus `log_streams` (DAT-001 - per-attempt VictoriaLogs stream bookkeeping, not log content). `backups`, `artifacts`,
## `environments`, `deployments`, `credentials`, `outbox`, `audit_events` are not created yet; `organizations` is the record only (the namespace,
## controller and Ingress of SHD-007 are not created by the core yet). Identifiers are UUIDv7 with a shard prefix (SHD-004); one shard is hardcoded, no
## directory yet.

import std/[json, times]
import uniq
import ../common/rqlite

const shardId* = "s1"  ## single shard, no directory yet (stage M5 of the roadmap adds it)

proc newId*(): string = shardId & "_" & $uuid7()

const ddl = [
  # the organisations of this shard (SHD-001, SHD-007); id doubles as tenant_id everywhere else
  """CREATE TABLE IF NOT EXISTS organizations (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, slug TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
       state TEXT NOT NULL DEFAULT 'active', settings TEXT NOT NULL DEFAULT '{}', plan TEXT NOT NULL DEFAULT '',
       created_at TEXT NOT NULL)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS organizations_slug ON organizations (slug)",
  """CREATE TABLE IF NOT EXISTS runs (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, project_id TEXT NOT NULL, bundle_id TEXT,
       trigger_id TEXT, parent_run_id TEXT, state TEXT NOT NULL, actor_id TEXT,
       version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
  "CREATE INDEX IF NOT EXISTS runs_project_created ON runs (project_id, created_at)",
  """CREATE TABLE IF NOT EXISTS run_journal (
       run_id TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL,
       payload TEXT NOT NULL, result TEXT NOT NULL, created_at TEXT NOT NULL,
       PRIMARY KEY (run_id, seq))""",
  """CREATE TABLE IF NOT EXISTS jobs (
       id TEXT PRIMARY KEY, run_id TEXT NOT NULL, key TEXT NOT NULL, state TEXT NOT NULL,
       profile_id TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 1, version INTEGER NOT NULL DEFAULT 1)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS jobs_run_key_attempt ON jobs (run_id, key, attempt)",
  # `ordinal` is the run_journal `seq` of the `job_sh` call this step answers (StepRef.seq, common.proto);
  # it is how the executor's replay and the job-controller's Pod name (`ci-<run>-<seq>-<attempt>`) line up.
  """CREATE TABLE IF NOT EXISTS steps (
       id TEXT PRIMARY KEY, run_id TEXT NOT NULL, job_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
       type TEXT NOT NULL, state TEXT NOT NULL, wait_reason TEXT, priority INTEGER NOT NULL DEFAULT 0,
       profile_id TEXT NOT NULL, image TEXT NOT NULL, command TEXT NOT NULL,
       controller_id TEXT, pod_name TEXT, exit_code INTEGER, termination TEXT, stdout TEXT,
       version INTEGER NOT NULL DEFAULT 1, queued_at TEXT NOT NULL, started_at TEXT, finished_at TEXT,
       attempt INTEGER NOT NULL DEFAULT 1, not_before INTEGER NOT NULL DEFAULT 0,
       opts TEXT NOT NULL DEFAULT '',
       shim_n INTEGER NOT NULL DEFAULT 0, shim_phase TEXT NOT NULL DEFAULT '', shim_json TEXT NOT NULL DEFAULT '',
       shim_seen_at INTEGER NOT NULL DEFAULT 0, shim_source TEXT NOT NULL DEFAULT '',
       claimed_at INTEGER NOT NULL DEFAULT 0)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS steps_run_ordinal ON steps (run_id, ordinal)",
  "CREATE INDEX IF NOT EXISTS steps_state_profile_priority ON steps (state, profile_id, priority)",
  """CREATE TABLE IF NOT EXISTS job_controllers (
       id TEXT PRIMARY KEY, cluster_id TEXT NOT NULL, identity TEXT NOT NULL, state TEXT NOT NULL,
       version INTEGER NOT NULL DEFAULT 1)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS job_controllers_identity ON job_controllers (identity)",
  """CREATE TABLE IF NOT EXISTS leases (
       scope TEXT PRIMARY KEY, owner TEXT NOT NULL, token TEXT NOT NULL, expires_at TEXT NOT NULL)""",
  """CREATE TABLE IF NOT EXISTS execution_profiles (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, name TEXT NOT NULL, cluster_id TEXT NOT NULL,
       namespace TEXT NOT NULL, node_selector TEXT NOT NULL DEFAULT '{}', runtime_class TEXT,
       resources TEXT NOT NULL DEFAULT '{}', storage_class TEXT, network_class TEXT,
       trust_level TEXT NOT NULL DEFAULT 'trusted', max_parallel INTEGER NOT NULL DEFAULT 100,
       infra_retries INTEGER NOT NULL DEFAULT 3, log_max_bytes INTEGER NOT NULL DEFAULT 1073741824,
       liveness_timeout INTEGER NOT NULL DEFAULT 300,
       log_spool_bytes INTEGER NOT NULL DEFAULT 10485760, log_hold_timeout INTEGER NOT NULL DEFAULT 600)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS execution_profiles_tenant_name ON execution_profiles (tenant_id, name)",
  # index_name is the VictoriaLogs "job" label value written by the collector (the step's Pod name) -
  # lets a reader reconstruct the LogsQL query from this row alone (spec line 838's column list).
  # one stream per *attempt* (D-27): a retried step writes a new stream under its own VictoriaLogs `job` label
  """CREATE TABLE IF NOT EXISTS log_streams (
       job_id TEXT NOT NULL, step_id TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 1, index_name TEXT NOT NULL,
       line_count INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'open', closed_at TEXT,
       PRIMARY KEY (job_id, step_id, attempt))""",
]

proc hasColumn(c: var RqClient; table, column: string): bool =
  let r = c.query(%*[["SELECT count(*) FROM pragma_table_info(?) WHERE name = ?", table, column]])
  r["results"][0]{"values"}[0][0].getInt > 0

proc migrate*(c: var RqClient) =
  # log_streams was created one day before it gained `attempt` (it is bookkeeping only, rebuilt on first use) - a primary
  # key cannot be altered in place, so an older table is dropped before the current DDL recreates it
  if not c.hasColumn("log_streams", "attempt") and c.query(%*[["SELECT count(*) FROM sqlite_master WHERE name = 'log_streams'"]])["results"][0]{"values"}[0][0].getInt > 0:
    discard c.execute(%*[["DROP TABLE log_streams"]])
  var stmts = newJArray()
  for s in ddl: stmts.add %s
  discard c.execute(stmts, transaction = true)
  # columns added after a table already existed in a shard (CREATE TABLE IF NOT EXISTS leaves old tables alone)
  for (table, column, definition) in [
      ("steps", "attempt", "INTEGER NOT NULL DEFAULT 1"), ("steps", "not_before", "INTEGER NOT NULL DEFAULT 0"),
      ("steps", "opts", "TEXT NOT NULL DEFAULT ''"),      # the Lua step options as one JSON object (mask, metrics, timeout)
      # the shim's last known state (D-29): the same JSON as its Pod-log line, numbered by event
      ("steps", "shim_n", "INTEGER NOT NULL DEFAULT 0"), ("steps", "shim_phase", "TEXT NOT NULL DEFAULT ''"),
      ("steps", "shim_json", "TEXT NOT NULL DEFAULT ''"), ("steps", "shim_seen_at", "INTEGER NOT NULL DEFAULT 0"),
      ("steps", "shim_source", "TEXT NOT NULL DEFAULT ''"), ("steps", "claimed_at", "INTEGER NOT NULL DEFAULT 0"),
      ("runs", "profile_id", "TEXT NOT NULL DEFAULT ''"),     # the execution profile of the run's organisation (SHD-007)
      ("execution_profiles", "infra_retries", "INTEGER NOT NULL DEFAULT 3"),
      ("execution_profiles", "log_max_bytes", "INTEGER NOT NULL DEFAULT 1073741824"),
      ("execution_profiles", "liveness_timeout", "INTEGER NOT NULL DEFAULT 300"),
      ("execution_profiles", "log_spool_bytes", "INTEGER NOT NULL DEFAULT 10485760"),
      ("execution_profiles", "log_hold_timeout", "INTEGER NOT NULL DEFAULT 600")]:
    if not c.hasColumn(table, column):
      discard c.execute(%*[["ALTER TABLE " & table & " ADD COLUMN " & column & " " & definition]])

proc seedDefaultProfile*(c: var RqClient; namespace: string; id = "default"): string =
  ## Idempotent: the one execution profile needed for now (there is no admin UI to create one yet).
  let r = c.query(%*[["SELECT id FROM execution_profiles WHERE tenant_id = 't1' AND name = ?", id]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: return vals[0][0].getStr
  let pid = newId()
  discard c.execute(%*[["INSERT INTO execution_profiles (id, tenant_id, name, cluster_id, namespace) " &
    "VALUES (?, 't1', ?, 'default', ?)", pid, id, namespace]])
  pid

# ------------------------------------------------------------------ log_streams (DAT-001)

proc openLogStream*(c: var RqClient; jobId, stepId: string; attempt: int; indexName: string) =
  ## Called by the collector on the first batch it sees for a step attempt. Idempotent: a retried/duplicate open
  ## (e.g. the shim reconnects) must not fail the whole batch.
  try:
    discard c.execute(%*[["INSERT INTO log_streams (job_id, step_id, attempt, index_name) VALUES (?, ?, ?, ?)",
      jobId, stepId, attempt, indexName]])
  except RqError:
    discard   # already open: fine, (job_id, step_id, attempt) is the primary key

proc closeLogStream*(c: var RqClient; jobId, stepId: string; attempt, lineCount: int) =
  ## Called from the StepReport handler once the shim's process ends (logcollector.nim).
  discard c.execute(%*[["UPDATE log_streams SET state = 'closed', line_count = ?, closed_at = ? " &
    "WHERE job_id = ? AND step_id = ? AND attempt = ?", lineCount, $getTime().toUnix(), jobId, stepId, attempt]])

proc abandonLogStream*(c: var RqClient; stepId: string; attempt: int) =
  ## The attempt was lost and the step went back to the queue: what it wrote stays (under its own label) but is marked.
  discard c.execute(%*[["UPDATE log_streams SET state = 'abandoned', closed_at = ? WHERE step_id = ? AND attempt = ? AND state = 'open'",
    $getTime().toUnix(), stepId, attempt]])

proc streamIndexName*(c: var RqClient; jobId, stepId: string): string =
  ## The newest attempt's stream. "" if none has been opened yet (core/api.nim's log-window read 404s on that).
  let r = c.query(%*[["SELECT index_name FROM log_streams WHERE job_id = ? AND step_id = ? ORDER BY attempt DESC LIMIT 1", jobId, stepId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

# ------------------------------------------------------------------ organizations (SHD-001, SHD-007)

proc listOrganizationRows*(c: var RqClient): seq[tuple[id, slug, name, state: string]] =
  let r = c.query(%*[["SELECT id, slug, name, state FROM organizations ORDER BY slug"]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals: result.add (v[0].getStr, v[1].getStr, v[2].getStr, v[3].getStr)

proc addOrganization*(c: var RqClient; slug, name: string): string =
  ## the record only; raises RqError when the slug exists (the unique index)
  let id = newId()
  discard c.execute(%*[["INSERT INTO organizations (id, tenant_id, slug, name, created_at) VALUES (?, ?, ?, ?, ?)",
    id, id, slug, name, $getTime().toUnix()]])
  id

proc organizationState*(c: var RqClient; slug: string): string =
  ## "" if the shard has no such organisation
  let r = c.query(%*[["SELECT state FROM organizations WHERE slug = ?", slug]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc setOrganizationState*(c: var RqClient; slug, state: string) =
  discard c.execute(%*[["UPDATE organizations SET state = ? WHERE slug = ?", state, slug]])

proc organizationRow*(c: var RqClient; slug: string): tuple[id, state: string] =
  ## ("", "") if the shard has no such organisation
  let r = c.query(%*[["SELECT id, state FROM organizations WHERE slug = ?", slug]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: (vals[0][0].getStr, vals[0][1].getStr) else: ("", "")

proc deleteOrganization*(c: var RqClient; slug: string) =
  ## the record and its execution profile; its runs and the rest are the organisation's data and go with the tenant's own
  ## deletion (not built yet)
  let o = c.organizationRow(slug)
  if o.id.len > 0: discard c.execute(%*[["DELETE FROM execution_profiles WHERE tenant_id = ?", o.id]])
  discard c.execute(%*[["DELETE FROM organizations WHERE slug = ?", slug]])

# ------------------------------------------------------------------ execution profile of an organisation (SHD-007)

proc ensureOrganizationProfile*(c: var RqClient; orgId, namespace: string): string =
  ## Every organisation has a profile of its own (default settings) that places its steps in its namespace; made on the first run.
  let r = c.query(%*[["SELECT id FROM execution_profiles WHERE tenant_id = ? AND name = 'default'", orgId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: return vals[0][0].getStr
  let pid = newId()
  discard c.execute(%*[["INSERT INTO execution_profiles (id, tenant_id, name, cluster_id, namespace) VALUES (?, ?, 'default', 'default', ?)",
    pid, orgId, namespace]])
  pid

proc profileOfNamespace*(c: var RqClient; namespace: string): string =
  ## the profile whose steps run in that namespace; "" if there is none
  let r = c.query(%*[["SELECT id FROM execution_profiles WHERE namespace = ? ORDER BY tenant_id LIMIT 1", namespace]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc profileOfRun*(c: var RqClient; runId, fallback: string): string =
  ## the profile of the run's organisation; `fallback` (the shard's default profile) for a run made without one
  let r = c.query(%*[["SELECT profile_id FROM runs WHERE id = ?", runId]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0 and vals[0][0].getStr.len > 0: vals[0][0].getStr else: fallback
