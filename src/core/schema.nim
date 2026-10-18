## Shard rqlite schema, the implemented subset (spec 8.2): `runs`, `run_journal`, `jobs`, `steps` (with the attempt, the Lua options
## and the shim's last state: shim_*, D-29), `job_controllers`, `leases`, `execution_profiles` (the settings of docs/settings.md)
## plus `log_streams` (DAT-001 - per-attempt VictoriaLogs stream bookkeeping, not log content). `backups`, `artifacts`,
## `environments`, `deployments`, `credentials`, `outbox`, `audit_events` are not created yet; `organizations` is the record only (the namespace,
## controller and Ingress of SHD-007 are not created by the core yet). Identifiers are UUIDv7 with a shard prefix (SHD-004); one shard is hardcoded, no
## directory yet.

import std/[json, times]
import uniq
import ../common/[rqlite, ctrlauth]

const shardId* = "s1"  ## single shard, no directory yet (stage M5 of the roadmap adds it)

proc newId*(): string = shardId & "_" & $uuid7()

const ddl = [
  # the organisations of this shard (SHD-001, SHD-007); id doubles as tenant_id everywhere else
  """CREATE TABLE IF NOT EXISTS organizations (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, slug TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
       state TEXT NOT NULL DEFAULT 'active', settings TEXT NOT NULL DEFAULT '{}', plan TEXT NOT NULL DEFAULT '',
       created_at TEXT NOT NULL,
       network_egress TEXT NOT NULL DEFAULT '',
       network_ingress TEXT NOT NULL DEFAULT '',
       disabled_at INTEGER NOT NULL DEFAULT 0)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS organizations_slug ON organizations (slug)",
  # the step secrets of an organisation (VAR-002, 6.7), each sealed with the organisation's data key (core/secretvault.nim); the data key is
  # wrapped by the master key, which is not in the database
  """CREATE TABLE IF NOT EXISTS step_secrets (
       tenant_id TEXT NOT NULL, name TEXT NOT NULL, version INTEGER NOT NULL, updated_at INTEGER NOT NULL, value_enc TEXT NOT NULL DEFAULT '',
       PRIMARY KEY (tenant_id, name))""",
  """CREATE TABLE IF NOT EXISTS org_keys (tenant_id TEXT PRIMARY KEY, wrapped TEXT NOT NULL, created_at INTEGER NOT NULL)""",
  """CREATE TABLE IF NOT EXISTS vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)""",
  # the API tokens (IAM-003, core/apiauth.nim): only the SHA-256 of the secret is kept; scope is `admin` or `org:<slug>`; 0 means never / not yet
  """CREATE TABLE IF NOT EXISTS api_tokens (
       id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', secret_hash TEXT NOT NULL, scope TEXT NOT NULL,
       created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL DEFAULT 0, last_used_at INTEGER NOT NULL DEFAULT 0,
       revoked_at INTEGER NOT NULL DEFAULT 0)""",
  # VAR-001, core/orgvars.nim: the plain variables of an organisation, put into the environment of its steps
  """CREATE TABLE IF NOT EXISTS org_variables (
       tenant_id TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (tenant_id, name))""",
  # DAT-003, D-27, core/drains.nim: a step whose artifacts or log the shim could not deliver (the core was not there): they are on the run's volume, and the controller of the
  # organisation fetches them when told. `state` is pending | done | failed.
  """CREATE TABLE IF NOT EXISTS step_drains (
       run_id TEXT NOT NULL, ordinal INTEGER NOT NULL, attempt INTEGER NOT NULL, profile_id TEXT NOT NULL, image TEXT NOT NULL DEFAULT '',
       volume TEXT NOT NULL DEFAULT '', artifacts INTEGER NOT NULL DEFAULT 0, logs INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'pending', tries INTEGER NOT NULL DEFAULT 0,
       next_at INTEGER NOT NULL DEFAULT 0, detail TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
       PRIMARY KEY (run_id, ordinal, attempt))""",
  "CREATE INDEX IF NOT EXISTS step_drains_state ON step_drains (profile_id, state, next_at)",
  # IAM-001, core/audit.nim: who did what to whom; also what the throttle of the login counts
  """CREATE TABLE IF NOT EXISTS audit_log (
       id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL DEFAULT '',
       outcome TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
       before TEXT NOT NULL DEFAULT '',
       after TEXT NOT NULL DEFAULT '')""",
  "CREATE INDEX IF NOT EXISTS audit_log_action ON audit_log (action, outcome, target, at)",
  # PIP-014, core/joblocks.nim: who holds the lock of a name in an organisation, and who waits for it, in the order of coming
  """CREATE TABLE IF NOT EXISTS run_locks (
       profile_id TEXT NOT NULL, name TEXT NOT NULL, run_id TEXT NOT NULL, depth INTEGER NOT NULL DEFAULT 1, acquired_at INTEGER NOT NULL,
       job_key TEXT NOT NULL DEFAULT '', PRIMARY KEY (profile_id, name))""",
  """CREATE TABLE IF NOT EXISTS lock_waiters (
       id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL UNIQUE, profile_id TEXT NOT NULL, name TEXT NOT NULL, call_key TEXT NOT NULL,
       payload TEXT NOT NULL, since INTEGER NOT NULL, job_key TEXT NOT NULL DEFAULT '')""",
  # IAM-001 (D-50): the users of the shard, the roles, and which user has which role at which level (`shard`: every organisation inherits it)
  """CREATE TABLE IF NOT EXISTS users (
       name TEXT PRIMARY KEY, password_hash TEXT NOT NULL, created_at INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0,
       must_change INTEGER NOT NULL DEFAULT 0)""",
  """CREATE TABLE IF NOT EXISTS roles (name TEXT PRIMARY KEY, description TEXT NOT NULL DEFAULT '')""",
  """CREATE TABLE IF NOT EXISTS role_bindings (
       user_name TEXT NOT NULL, role TEXT NOT NULL, scope TEXT NOT NULL DEFAULT 'shard', PRIMARY KEY (user_name, role, scope))""",
  # the identity of the job controller of an organisation's namespace (IAM-003, common/ctrlauth.nim): a generation, no secrets
  """CREATE TABLE IF NOT EXISTS controller_credentials (
       namespace TEXT PRIMARY KEY, generation INTEGER NOT NULL DEFAULT 1, confirmed INTEGER NOT NULL DEFAULT 0,
       bootstrap_expires_at INTEGER NOT NULL)""",
  """CREATE TABLE IF NOT EXISTS runs (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, group_id TEXT NOT NULL DEFAULT '', bundle_id TEXT,
       trigger_id TEXT, parent_run_id TEXT, state TEXT NOT NULL, actor_id TEXT,
       version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
       fail_code TEXT NOT NULL DEFAULT '',
       fail_message TEXT NOT NULL DEFAULT '',
       storage_released INTEGER NOT NULL DEFAULT 0,
       params TEXT NOT NULL DEFAULT '',
       profile_id TEXT NOT NULL DEFAULT '',
       api_version INTEGER NOT NULL DEFAULT 1,
       source_repository TEXT NOT NULL DEFAULT '',
       source_commit TEXT NOT NULL DEFAULT '',
       source_path TEXT NOT NULL DEFAULT '',
       journal_tip TEXT NOT NULL DEFAULT '',
       step_table TEXT NOT NULL DEFAULT '',
       lease_attempt INTEGER NOT NULL DEFAULT 0,
       lease_until INTEGER NOT NULL DEFAULT 0,
       lease_owner TEXT NOT NULL DEFAULT '',
       dirty INTEGER NOT NULL DEFAULT 0)""",
  # the triggers of an organisation (6.3, core/triggers.nim): a stored way to start a run, by the clock (`schedule`), by a call with the trigger's own secret (`webhook`),
  # or by hand; `secret_hash` is the SHA-256 of the webhook's secret (shown once)
  """CREATE TABLE IF NOT EXISTS triggers (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, schedule TEXT NOT NULL DEFAULT '',
       secret_hash TEXT NOT NULL DEFAULT '', group_id TEXT NOT NULL DEFAULT '', script TEXT NOT NULL, params TEXT NOT NULL DEFAULT '',
       repository TEXT NOT NULL DEFAULT '', ref TEXT NOT NULL DEFAULT '', script_path TEXT NOT NULL DEFAULT '',
       concurrency TEXT NOT NULL DEFAULT 'parallel', enabled INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL,
       last_fired_at INTEGER NOT NULL DEFAULT 0, last_run_id TEXT NOT NULL DEFAULT '', last_result TEXT NOT NULL DEFAULT '')""",
  # the artifacts of runs (DAT-003, core/objectstore.nim): the object is in the store, this is what the platform knows about it; a path is one artifact of a run
  """CREATE TABLE IF NOT EXISTS artifacts (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, run_id TEXT NOT NULL, step_ordinal INTEGER NOT NULL, path TEXT NOT NULL, s3_key TEXT NOT NULL,
       size INTEGER NOT NULL, sha256 TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL,
       upload_id TEXT NOT NULL DEFAULT '',
       store TEXT NOT NULL DEFAULT '')""",
  "CREATE UNIQUE INDEX IF NOT EXISTS artifacts_run_path ON artifacts (run_id, path)",
  "CREATE UNIQUE INDEX IF NOT EXISTS triggers_tenant_name ON triggers (tenant_id, name)",
  "CREATE INDEX IF NOT EXISTS runs_trigger ON runs (trigger_id, state)",
  # PRJ-001, D-54, core/groups.nim: the groups of an organisation, nested up to 8 levels (the organisation itself is the root and has no row; a run or a trigger with group_id ''
  # belongs to it). `path` is the slugs from the top joined by '/'; the variables of a group (VAR-001) are inherited by the groups below it and by its runs
  """CREATE TABLE IF NOT EXISTS groups (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, parent_id TEXT NOT NULL DEFAULT '', slug TEXT NOT NULL, path TEXT NOT NULL, depth INTEGER NOT NULL,
       created_at INTEGER NOT NULL)""",
  "CREATE UNIQUE INDEX IF NOT EXISTS groups_tenant_path ON groups (tenant_id, path)",
  "CREATE INDEX IF NOT EXISTS groups_parent ON groups (parent_id)",
  """CREATE TABLE IF NOT EXISTS group_variables (
       group_id TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (group_id, name))""",
  # DAT-004, core/cachestore.nim: the caches of an organisation, between runs. One entry is one object of the store, named by (organisation, scope, key); the scope is the group
  # (D-54) the run is in. A key is immutable: it is stored once.
  """CREATE TABLE IF NOT EXISTS caches (
       id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, scope TEXT NOT NULL DEFAULT '', key TEXT NOT NULL, s3_key TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0,
       sha256 TEXT NOT NULL DEFAULT '', state TEXT NOT NULL, upload_id TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL,
       store TEXT NOT NULL DEFAULT '')""",
  "CREATE UNIQUE INDEX IF NOT EXISTS caches_scope_key ON caches (tenant_id, scope, key)",
  "CREATE INDEX IF NOT EXISTS caches_used ON caches (tenant_id, last_used_at)",
  # DAT-004, core/cachestore.nim: the cache limits of a group (0 is nothing of its own: the group above decides, then the organisation, then the shard)
  """CREATE TABLE IF NOT EXISTS group_settings (
       group_id TEXT PRIMARY KEY, cache_quota_bytes INTEGER NOT NULL DEFAULT 0, cache_retention_days INTEGER NOT NULL DEFAULT 0)""",
  # DAT-006, core/holds.nim: a legal hold on a run forbids the garbage collection of what it left (its artifacts, its volume) and the deletion of its organisation
  """CREATE TABLE IF NOT EXISTS run_holds (
       run_id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, reason TEXT NOT NULL, placed_by TEXT NOT NULL, placed_at INTEGER NOT NULL)""",
  "CREATE INDEX IF NOT EXISTS run_holds_tenant ON run_holds (tenant_id)",
  # DAT-006: a legal hold on a group (and the groups below it) or, with group_id '', on the whole organisation: it covers the runs that are there and those made while it stands
  """CREATE TABLE IF NOT EXISTS scope_holds (
       tenant_id TEXT NOT NULL, group_id TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL, placed_by TEXT NOT NULL, placed_at INTEGER NOT NULL, PRIMARY KEY (tenant_id, group_id))""",
  # DAT-006, core/heldlogs.nim: the copy of the log of a step of a held run, kept in the object store while the hold stands
  """CREATE TABLE IF NOT EXISTS held_logs (
       run_id TEXT NOT NULL, ordinal INTEGER NOT NULL, attempt INTEGER NOT NULL, tenant_id TEXT NOT NULL, s3_key TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0,
       line_count INTEGER NOT NULL DEFAULT 0, complete INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL,
       store TEXT NOT NULL DEFAULT '',
       PRIMARY KEY (run_id, ordinal, attempt))""",
  # D-59: which store an organisation uses for a purpose (artifacts, caches, held_logs, audit); no row means the module's default. The stores themselves are the storage module's (D-60)
  """CREATE TABLE IF NOT EXISTS org_storage (
       tenant_id TEXT NOT NULL, purpose TEXT NOT NULL, store_name TEXT NOT NULL, updated_by TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL, PRIMARY KEY (tenant_id, purpose))""",
  # the variables of the shard itself, the lowest level (VAR-001, D-54): every step of every organisation of the shard gets them
  """CREATE TABLE IF NOT EXISTS shard_variables (
       name TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)""",
  """CREATE TABLE IF NOT EXISTS run_journal (
       run_id TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL,
       payload TEXT NOT NULL, result TEXT NOT NULL, created_at TEXT NOT NULL,
       call_key TEXT NOT NULL DEFAULT '',
       hash TEXT NOT NULL DEFAULT '',
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
       claimed_at INTEGER NOT NULL DEFAULT 0,
       retries INTEGER NOT NULL DEFAULT 0,
       profile TEXT NOT NULL DEFAULT '',
       pod_reason TEXT NOT NULL DEFAULT '',
       pod_message TEXT NOT NULL DEFAULT '',
       pod_diag TEXT NOT NULL DEFAULT '')""",
  "CREATE UNIQUE INDEX IF NOT EXISTS steps_run_ordinal ON steps (run_id, ordinal)",
  "CREATE UNIQUE INDEX IF NOT EXISTS run_journal_key ON run_journal (run_id, call_key) WHERE call_key != ''",      # a call has one record
  "CREATE INDEX IF NOT EXISTS runs_group ON runs (tenant_id, group_id)",
  "CREATE INDEX IF NOT EXISTS runs_storage ON runs (profile_id, storage_released, state)",    # what the polls of the controllers ask (core/runstorage.nim)
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
       log_spool_bytes INTEGER NOT NULL DEFAULT 10485760, log_hold_timeout INTEGER NOT NULL DEFAULT 600,
       pod_limit INTEGER NOT NULL DEFAULT 20,
       job_pod_limit_percent INTEGER NOT NULL DEFAULT 20,
       runs_per_conductor INTEGER NOT NULL DEFAULT 10,
       artifact_quota_bytes INTEGER NOT NULL DEFAULT 0,
       cache_quota_bytes INTEGER NOT NULL DEFAULT 0,
       cache_retention_days INTEGER NOT NULL DEFAULT 0,
       artifact_retention_days INTEGER NOT NULL DEFAULT 0,
       conductor_min INTEGER NOT NULL DEFAULT 1,
       audit_variables TEXT NOT NULL DEFAULT 'off')""",
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

const columnsAdded: seq[(string, string, string)] = @[
  ("step_drains", "volume", "TEXT NOT NULL DEFAULT ''"),      # STO-002: the id of the job whose volume the step used (2026-10-18)
  ("runs", "source_repository", "TEXT NOT NULL DEFAULT ''"),  # D-63: the repository, the commit and the path the run's script was read from (2026-10-18)
  ("runs", "source_commit", "TEXT NOT NULL DEFAULT ''"),
  ("runs", "source_path", "TEXT NOT NULL DEFAULT ''"),
  ("triggers", "repository", "TEXT NOT NULL DEFAULT ''"),     # D-63: a trigger whose script is read from a repository
  ("triggers", "ref", "TEXT NOT NULL DEFAULT ''"),
  ("triggers", "script_path", "TEXT NOT NULL DEFAULT ''")]
  ## Columns added to a table after a shard was made: `(table, column, definition)`, which `migrate` adds to a table that lacks them (`CREATE TABLE IF NOT EXISTS` leaves an existing table
  ## alone). The list was folded into the `CREATE TABLE`s on 2026-10-18 (docs/compat.md) and is empty: a column that is added from now on goes into its `CREATE TABLE` and, until the
  ## next fold, here too.

proc migrate*(c: var RqClient) =
  var stmts = newJArray()
  for s in ddl: stmts.add %s
  discard c.execute(stmts, transaction = true)
  for (table, column, definition) in columnsAdded:
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

proc addOrganization*(c: var RqClient; slug, name: string; egress = ""; ingress = ""): string =
  ## the record only; raises RqError when the slug exists (the unique index). `egress` and `ingress` are the network mode asked for at
  ## creation ("" = the shard's default), kept so that a later reconciliation (SHD-008) makes the same objects
  let id = newId()
  discard c.execute(%*[["INSERT INTO organizations (id, tenant_id, slug, name, created_at, network_egress, network_ingress) VALUES (?, ?, ?, ?, ?, ?, ?)",
    id, id, slug, name, $getTime().toUnix(), egress, ingress]])
  id

proc organizationNetwork*(c: var RqClient; slug: string): tuple[egress, ingress: string] =
  let r = c.query(%*[["SELECT network_egress, network_ingress FROM organizations WHERE slug = ?", slug]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: (vals[0][0].getStr, vals[0][1].getStr) else: ("", "")

proc organizationState*(c: var RqClient; slug: string): string =
  ## "" if the shard has no such organisation
  let r = c.query(%*[["SELECT state FROM organizations WHERE slug = ?", slug]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: vals[0][0].getStr else: ""

proc setOrganizationState*(c: var RqClient; slug, state: string) =
  ## `disabled_at` starts the retention period of a switched-off organisation and is cleared when it is anything else again
  discard c.execute(%*[["UPDATE organizations SET state = ?, disabled_at = ? WHERE slug = ?", state,
    (if state == "disabled": getTime().toUnix() else: 0'i64), slug]])

proc startRetention*(c: var RqClient; slug: string; at: int64) =
  ## an organisation switched off before `disabled_at` existed: the retention runs from now
  discard c.execute(%*[["UPDATE organizations SET disabled_at = ? WHERE slug = ? AND state = 'disabled' AND disabled_at = 0", at, slug]])

type OrganizationFull* = object
  ## `held`: how many of its runs are under a legal hold (DAT-006); an organisation with any is not deleted for good
  slug*, name*, state*, egress*, ingress*: string   ## egress and ingress: the network mode asked for at creation, "" = the shard's default
  disabledAt*: int64
  held*: int

proc listOrganizationsFull*(c: var RqClient): seq[OrganizationFull] =
  ## everything the reconciliation (SHD-008) needs to make an organisation's objects again
  let r = c.query(%*[["SELECT slug, name, state, network_egress, network_ingress, disabled_at, " &
    "(SELECT count(*) FROM run_holds h WHERE h.tenant_id = organizations.id) + (SELECT count(*) FROM scope_holds s WHERE s.tenant_id = organizations.id) FROM organizations ORDER BY slug"]])
  let vals = r["results"][0]{"values"}
  if vals != nil:
    for v in vals:
      result.add OrganizationFull(slug: v[0].getStr, name: v[1].getStr, state: v[2].getStr, egress: v[3].getStr, ingress: v[4].getStr,
                                  disabledAt: v[5].getBiggestInt, held: v[6].getInt)

proc organizationRow*(c: var RqClient; slug: string): tuple[id, state: string] =
  ## ("", "") if the shard has no such organisation
  let r = c.query(%*[["SELECT id, state FROM organizations WHERE slug = ?", slug]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: (vals[0][0].getStr, vals[0][1].getStr) else: ("", "")

proc deleteOrganization*(c: var RqClient; slug: string) =
  ## the record and its execution profile; its runs and the rest are the organisation's data and go with the tenant's own
  ## deletion (not built yet)
  let o = c.organizationRow(slug)
  if o.id.len > 0:
    discard c.execute(%*[["DELETE FROM execution_profiles WHERE tenant_id = ?", o.id]])
    discard c.execute(%*[["DELETE FROM step_secrets WHERE tenant_id = ?", o.id]])
    discard c.execute(%*[["DELETE FROM triggers WHERE tenant_id = ?", o.id]])
    discard c.execute(%*[["DELETE FROM org_storage WHERE tenant_id = ?", o.id]])
    discard c.execute(%*[["DELETE FROM artifacts WHERE tenant_id = ?", o.id]])      # the objects stay in the store until a sweeper removes them (not built)
    discard c.execute(%*[["DELETE FROM org_keys WHERE tenant_id = ?", o.id]])
  discard c.execute(%*[["DELETE FROM organizations WHERE slug = ?", slug]])

# ------------------------------------------------------------------ execution profile of an organisation (SHD-007)

proc ensureOrganizationProfile*(c: var RqClient; orgId, namespace: string; name = "default"): string =
  ## Every organisation has a profile of its own (default settings) that places its steps in its namespace; made on the first run.
  let r = c.query(%*[["SELECT id FROM execution_profiles WHERE tenant_id = ? AND name = ?", orgId, name]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0: return vals[0][0].getStr
  let pid = newId()
  discard c.execute(%*[["INSERT INTO execution_profiles (id, tenant_id, name, cluster_id, namespace) VALUES (?, ?, ?, 'default', ?)",
    pid, orgId, name, namespace]])
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

# ------------------------------------------------------------------ identity of the controller of a namespace (IAM-003, T-46)

proc credentialRow*(c: var RqClient; namespace: string): CredentialRow =
  let r = c.query(%*[["SELECT generation, confirmed, bootstrap_expires_at FROM controller_credentials WHERE namespace = ?", namespace]])
  let vals = r["results"][0]{"values"}
  if vals != nil and vals.len > 0:
    CredentialRow(found: true, generation: vals[0][0].getInt, confirmed: vals[0][1].getInt != 0, bootstrapExpiresAt: vals[0][2].getBiggestInt)
  else: CredentialRow()

proc ensureCredentialRow*(c: var RqClient; namespace: string; expiresAt: int64) =
  ## made with the namespace; asking again (a retried provisioning) leaves the generation and the expiry as they are
  discard c.execute(%*[["INSERT OR IGNORE INTO controller_credentials (namespace, generation, confirmed, bootstrap_expires_at) VALUES (?, 1, 0, ?)",
    namespace, expiresAt]])

proc confirmCredential*(c: var RqClient; namespace: string) =
  discard c.execute(%*[["UPDATE controller_credentials SET confirmed = 1 WHERE namespace = ?", namespace]])

proc rotateCredential*(c: var RqClient; namespace: string; expiresAt: int64) =
  ## a new generation: the old credential and the old bootstrap token stop working, a new bootstrap token is due
  discard c.execute(%*[["UPDATE controller_credentials SET generation = generation + 1, confirmed = 0, bootstrap_expires_at = ? WHERE namespace = ?",
    expiresAt, namespace]])

proc deleteCredentialRow*(c: var RqClient; namespace: string) =
  discard c.execute(%*[["DELETE FROM controller_credentials WHERE namespace = ?", namespace]])
