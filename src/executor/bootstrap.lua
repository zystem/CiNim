-- Sandbox bootstrap: runs once with the real globals, returns the read-only
-- environment table that user scripts see as _ENV (PIP-005).
local G = _G
-- The only thing of the debug interface that is needed: the line of the script on which a step is made (the place of the step in the table of docs/parallel.md section 3.4).
-- The host gives a function for it (lua_glue.c); the closures below keep it and the global is removed at once, so a script cannot reach it.
local getline = G.__ci_line
G.__ci_line = nil
local type, error, rawget, rawset, rawlen, rawnext = type, error, rawget, rawset, rawlen, next
local getmetatable, setmetatable, tostring_ = getmetatable, setmetatable, tostring
local mtype = math.type
local tsort, tconcat = table.sort, table.concat
local load_, collect_ = load, collectgarbage
local format_ = string.format

local function safe_tostring(v)
  local t = type(v)
  if t == "table" or t == "function" or t == "thread" or t == "userdata" then
    local mt = getmetatable(v)
    if type(mt) == "table" and rawget(mt, "__tostring") then return tostring_(v) end
    return t
  end
  return tostring_(v)
end

local rank = { boolean = 1, number = 2, string = 3 }
local function keycmp(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return rank[ta] < rank[tb] end
  if ta == "boolean" then return (not a) and b end
  return a < b
end

-- Sequence part first, then the other keys sorted by type and value.
local function stable_pairs(t)
  if type(t) ~= "table" then
    error("bad argument #1 to 'pairs' (table expected, got " .. type(t) .. ")", 2)
  end
  local n = rawlen(t)
  local rest, r = {}, 0
  for k in rawnext, t do
    if not (mtype(k) == "integer" and k >= 1 and k <= n) then
      if not rank[type(k)] then
        error("script_nondeterminism: " .. type(k) .. " keys have no stable order", 2)
      end
      r = r + 1
      rest[r] = k
    end
  end
  tsort(rest, keycmp)
  local i = 0
  return function()
    i = i + 1
    local k
    if i <= n then k = i else k = rest[i - n] end
    if k ~= nil then return k, rawget(t, k) end
  end, t, nil
end

local proxy = {}
setmetatable(proxy, {
  __index = G,
  __newindex = function(_, k)
    error("global environment is read-only (assignment to '" .. tostring_(k) .. "')", 2)
  end,
  __metatable = false,
})

G.dofile, G.loadfile, G.print, G.next = nil, nil, nil, nil
math.random, math.randomseed, string.dump = nil, nil, nil

G.pairs = stable_pairs
G.tostring = safe_tostring

G.load = function(chunk, name, _, ...)
  if type(chunk) ~= "string" then error("load: only text chunks are accepted", 2) end
  if select("#", ...) == 0 then return load_(chunk, name or chunk, "t", proxy) end
  return load_(chunk, name or chunk, "t", ...)
end

G.collectgarbage = function(opt)
  if opt == nil or opt == "collect" then collect_("collect") return 0 end
  error("collectgarbage: option '" .. tostring_(opt) .. "' is not allowed", 2)
end

G.rawset = function(t, k, v)
  if t == proxy then error("global environment is read-only (rawset)", 2) end
  return rawset(t, k, v)
end

string.format = function(fmt, ...)
  if type(fmt) == "string" and fmt:gsub("%%%%", ""):find("%%[%-+ #0]*%d*%.?%d*p") then
    error("string.format: '%p' would expose addresses", 2)
  end
  local args = table.pack(...)
  for i = 1, args.n do
    local v = args[i]
    local t = type(v)
    if t == "table" or t == "function" or t == "thread" or t == "userdata" then
      args[i] = safe_tostring(v)
    end
  end
  return format_(fmt, table.unpack(args, 1, args.n))
end

-- Host API: each call yields to the Nim driver, which either replays the journaled result or performs the call (PIP-003). Where the call is made matters (docs/parallel.md
-- sections 3.1 and 5): `main` and every branch of `ci.parallel` is a *context* with a path (`m`, `m.p1[unit]`, `m.p1[unit].p2[x]`) and counters of its own, so that the identity of a
-- call is a function of the structure of the script and never of the order in which the host happened to answer. A branch is a coroutine; its host calls are not made by it
-- but handed up to the scheduler of `ci.parallel`, which hands them on, and the answer is `nil` when the call is pending (a step that waits or runs): the branch then parks
-- and the others go on. When nothing can go on the run is suspended; a parked branch is never asked again in the same execution, because nothing it waits for can change in it.
local yield_, running = coroutine.yield, coroutine.running
local cocreate, cresume, cstatus = coroutine.create, coroutine.resume, coroutine.status
local state = {}
local branch_co = setmetatable({}, { __mode = "k" })       -- the coroutines that are branches of ci.parallel

local CANCELED = "~canceled:"     -- the journaled answer of a step that a ci.parallel cancelled; followed by the path of that ci.parallel

local function new_ctx(path, depth) return { path = path, depth = depth, kn = {}, ln = {}, jobs = 0, pars = 0 } end
local cur = new_ctx("m", 0)                                -- the context the running code belongs to

local function park()
  if running() == state.main then yield_("__suspend") else yield_({ kind = "__park" }) end
end

local function call(kind, payload, line, stepno)
  local co = running()
  if co ~= state.main and not branch_co[co] then
    error("ci." .. kind .. ": host calls are not supported inside nested coroutines", 3)
  end
  local ctx = cur
  local nth
  if kind == "job_sh" then                                 -- a step is told apart by its number, made of the id of its job and its own (D-67): the same in every replay, whatever the branches do
    nth = stepno
  else
    nth = ctx.kn[kind] or 0
    ctx.kn[kind] = nth + 1
  end
  if co == state.main then
    local a = yield_(kind, payload, line or 0, ctx.path, nth)
    if a == nil then park() end                            -- pending and nothing else to do: the run waits
    if a:sub(1, #CANCELED) == CANCELED then error("step canceled", 3) end
    return a
  end
  local a = yield_({ kind = kind, payload = payload, line = line or 0, ctx = ctx.path, nth = nth })
  if a == nil then park() end
  if a:sub(1, #CANCELED) == CANCELED then            -- the step was cancelled by the decision of a ci.parallel (fail_fast): this branch is over, and is never resumed
    yield_({ kind = "__canceled", by = a:sub(#CANCELED + 1) })
  end
  return a
end

-- a call that is not made by the script and has no place in its counters: the decision of fail_fast and the look for it in the journal (replay.nim `par_cancel`, `par_peek`)
local function raw_call(kind, payload, ctx)
  if running() == state.main then return yield_(kind, payload, 0, ctx, 0) end
  return yield_({ kind = kind, payload = payload, line = 0, ctx = ctx, nth = 0 })
end

coroutine.yield = function(...)
  local co = running()
  if co == state.main or branch_co[co] then
    error("coroutine.yield is reserved for host calls in the main script", 2)
  end
  return yield_(...)
end

-- Lua API v1 (6.7, lua/stdlib/cicd.d.lua), stage-1 subset: ci.pipeline, ci.job, Job:sh. One
-- `Job:sh` call is one step (RUN-002); `ci.job` itself is plain Lua control flow, not a host call,
-- same as `for`/`pcall` are not journaled --- only what a job's steps actually do is (PIP-003).
-- `use`, `ci.input`, services and `ci.spawn` are not implemented yet (`ci.parallel` and `ci.matrix` are: docs/parallel.md).

-- The limit of steps in a run and the ids that the author gives to jobs and steps (D-67). A run has at most 1000 steps: the 1001st is an error returned to the author (`step_limit`).
-- An id is Crockford base32 in lowercase, `0123456789abcdefghjkmnpqrstvwxyz` (the digits and the letters but i l o u), of a fixed width: a job's 2 characters, a step's 4. A shorter id is
-- padded with zeros in front (`a` is `0a`), upper case is read as lower case, so `a`, `A` and `0a` are one id. The id of a job is unique in the run and the id of a step in its job: a
-- repeat is the author's to resolve, the run fails with `duplicate_id` and the two lines. The script runs again in a fresh state at every replay, so these checks are made again each time.
-- A step is told to the host by one number, `job * 2^20 + step`: it is the same in every replay and no table is needed (src/common/crockford.nim has the same rules for the core).
local MAX_STEPS = 1000
local step_count = 0
local job_ids = {}                       -- the normalized id of a job -> the line where it was first used
local ID_DIGITS = "0123456789abcdefghjkmnpqrstvwxyz"
local JOB_ID_WIDTH, STEP_ID_WIDTH = 2, 4

local function id_number(s)
  local n = 0
  for i = 1, #s do n = n * 32 + (ID_DIGITS:find(s:sub(i, i), 1, true) - 1) end
  return n
end

-- the id `v` of at most `width` characters, normalized; an error for anything else. `what` names the call, for the message; the error is at the line of the script (level 3 from the
-- function that makes the id: it is called by the index of `ci.single[...]` or of `step.sh[...]`, which the script calls)
local function norm_ref(v, width, what)
  if type(v) ~= "string" then error(what .. ": an id is a string of at most " .. width .. " characters of 0-9 and a-z without i, l, o, u, got " .. type(v), 3) end
  if #v == 0 then error(what .. ": an id is not empty", 3) end
  if #v > width then error(what .. ": an id is at most " .. width .. " characters, got " .. #v .. " ('" .. v .. "')", 3) end
  local lower = v:lower()
  for i = 1, #lower do
    local c = lower:sub(i, i)
    if not ID_DIGITS:find(c, 1, true) then
      if c == "i" or c == "l" or c == "o" or c == "u" then
        error(what .. ": the character '" .. c .. "' is not in the alphabet of ids (i, l, o and u are left out: write 1 for i and l, 0 for o)", 3)
      end
      error(what .. ": the character '" .. v:sub(i, i) .. "' is not in the alphabet of ids (digits and the letters but i, l, o, u)", 3)
    end
  end
  return string.rep("0", width - #lower) .. lower
end

-- the same without an error: nil for what is not an id (a lookup in the results by an id as the author writes it)
local function try_ref(v, width)
  if type(v) ~= "string" or #v == 0 or #v > width then return nil end
  local lower = v:lower()
  if lower:find("[^" .. ID_DIGITS .. "]") then return nil end
  return string.rep("0", width - #lower) .. lower
end

local function claim_job(id, line)
  local first = job_ids[id]
  if first then error("duplicate_id: the job id '" .. id .. "' is used at line " .. first .. " and again at line " .. line, 0) end
  job_ids[id] = line
end

-- the name of a branch of `ci.parallel` (D-69 will replace the branches by jobs): letters and digits, a letter first, at most 8
local function check_branch(v, what)
  if v == nil then return nil end
  if type(v) ~= "string" or #v > 8 or not v:find("^[A-Za-z][A-Za-z0-9]*$") then
    error(what .. ": a name is 1 to 8 letters and digits starting with a letter, got " .. (type(v) == "string" and ("'" .. v .. "'") or type(v)), 3)
  end
  return v
end

-- Application metrics of a step (`metrics = {...}` in ci.job / Job:sh options). The shim in the step's Pod reads them
-- (docs/metrics.md); here the table is validated and reduced to one canonical JSON string, so the same declaration is
-- always the same bytes in the journal (PIP-003) and the shim never meets an unchecked value. Limits keep a script from
-- turning the Pod into a scraper of arbitrary targets: loopback only, a handful of endpoints, bounded patterns.
local METRICS_MAX_SCRAPES, METRICS_MAX_INCLUDE, METRICS_PATTERN_MAX = 4, 32, 128
local METRIC_RUNTIMES = { auto = true, jvm = true, none = true }
local METRIC_FORMATS = { prometheus = true, expvar = true }

local function jstr(v)
  return '"' .. v:gsub('[%c"\\]', function(c)
    return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" })[c]
      or format_("\\u%04x", c:byte())
  end) .. '"'
end

local function parse_duration(v, what)
  if mtype(v) == "integer" or (type(v) == "number" and v == v // 1) then return math.tointeger(v) end
  if type(v) == "string" then
    local n, unit = v:match("^(%d+)([smh])$")
    if n then return tonumber(n) * ({ s = 1, m = 60, h = 3600 })[unit] end
  end
  error("metrics: " .. what .. " must be whole seconds or a string like \"15s\", \"2m\"", 4)
end

local function norm_scrape(sc, i)
  if type(sc) ~= "table" then error("metrics.scrape[" .. i .. "]: table expected", 4) end
  for k in rawnext, sc do
    if k ~= "url" and k ~= "name" and k ~= "interval" and k ~= "timeout" and k ~= "format" and k ~= "include" then
      error("metrics.scrape[" .. i .. "]: unknown field '" .. tostring_(k) .. "'", 4)
    end
  end
  local url = sc.url
  if type(url) ~= "string" then error("metrics.scrape[" .. i .. "].url: string expected", 4) end
  local host = url:match("^http://(%[::1%])") or url:match("^http://([^/:]+)")
  if not (host == "127.0.0.1" or host == "localhost" or host == "[::1]") or url:find("[%s%c\"\\]") then
    error("metrics.scrape[" .. i .. "].url: only http://127.0.0.1, localhost or [::1] (the step's own Pod) may be scraped", 4)
  end
  local interval = sc.interval ~= nil and parse_duration(sc.interval, "interval") or 15
  local timeout = sc.timeout ~= nil and parse_duration(sc.timeout, "timeout") or math.min(interval, 5)
  if interval < 1 or interval > 300 then error("metrics.scrape[" .. i .. "].interval: 1s..5m", 4) end
  if timeout < 1 or timeout > interval then error("metrics.scrape[" .. i .. "].timeout: 1s..interval", 4) end
  local format = sc.format or "prometheus"
  if not METRIC_FORMATS[format] then error("metrics.scrape[" .. i .. "].format: prometheus or expvar", 4) end
  local name = sc.name or ("app" .. i)
  if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_]*$") or #name > 32 then
    error("metrics.scrape[" .. i .. "].name: lowercase letters, digits and _, up to 32", 4)
  end
  local inc = sc.include or {}
  if type(inc) ~= "table" or rawlen(inc) > METRICS_MAX_INCLUDE then
    error("metrics.scrape[" .. i .. "].include: list of at most " .. METRICS_MAX_INCLUDE .. " name patterns", 4)
  end
  local pats = {}
  for j = 1, rawlen(inc) do
    local pt = inc[j]
    if type(pt) ~= "string" or #pt == 0 or #pt > METRICS_PATTERN_MAX or not pt:match("^[%w_:%*]+$") then
      error("metrics.scrape[" .. i .. "].include[" .. j .. "]: a metric name, '*' allowed as a wildcard", 4)
    end
    pats[j] = jstr(pt)
  end
  return format_('{"format":%s,"include":[%s],"interval":%d,"name":%s,"timeout":%d,"url":%s}',
    jstr(format), table.concat(pats, ","), interval, jstr(name), timeout, jstr(url))
end

-- returns the canonical JSON ("" = no application metrics); `false` switches a job-level declaration off for one step
local function norm_metrics(m)
  if m == nil or m == false then return "" end
  if type(m) ~= "table" then error("metrics: table expected", 3) end
  for k in rawnext, m do
    if k ~= "runtime" and k ~= "scrape" then error("metrics: unknown field '" .. tostring_(k) .. "'", 3) end
  end
  local runtime = m.runtime or "none"
  if not METRIC_RUNTIMES[runtime] then error("metrics.runtime: auto, jvm or none", 3) end
  local scrapes = m.scrape or {}
  if type(scrapes) ~= "table" or rawlen(scrapes) > METRICS_MAX_SCRAPES then
    error("metrics.scrape: list of at most " .. METRICS_MAX_SCRAPES .. " endpoints", 3)
  end
  local parts = {}
  for i = 1, rawlen(scrapes) do parts[i] = norm_scrape(scrapes[i], i) end
  if runtime == "none" and #parts == 0 then return "" end
  return format_('{"runtime":%s,"scrape":[%s]}', jstr(runtime), table.concat(parts, ","))
end

-- Secret masking (docs/secrets-masking.md). The shim always masks the values of the step's secrets; `mask` tunes how:
--   runtime   the build may add values to mask while it runs, by appending them to the file $CICD_MASK (default true)
--   variants  also mask the base64 (any alignment), URL-encoded and JSON-escaped forms of every value (default true)
--   min_length  values shorter than this are not masked, they would mangle ordinary output (4..64, default 4)
-- `mask = false` switches runtime values and variants off; nothing set = the defaults. Values never pass through Lua.
local function norm_mask(m)
  if m == nil then return "" end
  if m == false then return '{"min_length":4,"runtime":false,"variants":false}' end
  if type(m) ~= "table" then error("mask: table or false expected", 3) end
  for k in rawnext, m do
    if k ~= "runtime" and k ~= "variants" and k ~= "min_length" then error("mask: unknown field '" .. tostring_(k) .. "'", 3) end
  end
  local runtime, variants = m.runtime, m.variants
  if runtime == nil then runtime = true end
  if variants == nil then variants = true end
  if type(runtime) ~= "boolean" or type(variants) ~= "boolean" then error("mask.runtime and mask.variants: booleans", 3) end
  local min = m.min_length or 4
  if mtype(min) ~= "integer" or min < 4 or min > 64 then error("mask.min_length: an integer 4..64", 3) end
  return format_('{"min_length":%d,"runtime":%s,"variants":%s}', min, tostring_(runtime), tostring_(variants))
end

-- The step's timeout: whole seconds or "90s" / "15m" / "2h"; the shim ends the build after it (docs/ci-pitfalls.md)
-- `lock = "name"` of ci.job (PIP-014, core/joblocks.nim): the jobs of the organisation with the same lock run one at a time, in turn, also when they belong to different runs
local function norm_lock(v)
  if v == nil or v == false then return nil end
  if type(v) ~= "string" or #v < 1 or #v > 64 or v:find("[^%w%._:%-]") then
    error("ci.job: lock is a name of 1 to 64 letters, digits and . _ : -", 3)
  end
  return v
end

-- `workspace` of ci.job (STO-002): "shared" (the default) is the run's volume, every job sees it; "isolated" is a volume of the job's own, made for it and seen by no other job. The steps of a job
-- share it. It reaches the core in the options of each step, where "shared" says nothing.
local function norm_workspace(v)
  if v == nil or v == "shared" then return nil end
  if v ~= "isolated" then error("ci.job: workspace is \"shared\" or \"isolated\"", 3) end
  return v
end

-- `shm`: a /dev/shm of this size, backed by memory (a Pod has 64Mi of it unless asked): for what keeps its working data in memory, a database for tests above all, whose fsyncs
-- on a slow disk made the tests time out. It counts against the memory limit of the Pod. "64Mi" to "8Gi".
local function norm_shm(v)
  if v == nil then return nil end
  local n, unit = (type(v) == "string" and v or ""):match("^(%d+)(%a+)$")
  n = tonumber(n)
  if not n or (unit ~= "Mi" and unit ~= "Gi") then error("ci.job: shm is a size such as \"512Mi\" or \"2Gi\"", 3) end
  local mi = unit == "Gi" and n * 1024 or n
  if mi < 64 or mi > 8192 then error("ci.job: shm is from 64Mi to 8Gi", 3) end
  return v
end

local function norm_timeout(v)
  if v == nil or v == false then return nil end
  local s = parse_duration(v, "timeout")
  if s < 1 or s > 86400 then error("timeout: 1s..24h", 3) end
  return s
end

-- The secrets of a step (6.7, VAR-002): names only, never values. They are defined for the organisation (PUT /api/v1/organizations/{slug}/secrets/{NAME});
-- the job controller gives the step's container each as the environment variable of that name and the shim masks the value in the log. A job's list and
-- a step's are added together. Returns a sorted list without repeats, or nil when none was given.
local function norm_secrets(v, depth)
  if v == nil then return nil end
  if type(v) ~= "table" then error("secrets: a list of names, for example {\"REGISTRY_PASSWORD\"}", depth) end
  local names, seen = {}, {}
  for i = 1, rawlen(v) do
    local n = v[i]
    if type(n) ~= "string" or #n > 64 or not n:match("^[A-Z_][A-Z0-9_]*$") then
      error("secrets: a name is capital letters, digits and _, not starting with a digit, at most 64 characters", depth)
    end
    if not seen[n] then seen[n] = true; names[#names + 1] = n end
  end
  if #names > 32 then error("secrets: at most 32 per step", depth) end
  tsort(names)
  return names
end

local function merge_secrets(a, b)
  if a == nil then return b end
  if b == nil then return a end
  local names, seen = {}, {}
  for k = 1, 2 do
    local l = (k == 1) and a or b
    for i = 1, rawlen(l) do
      local n = l[i]
      if not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
  end
  if #names > 32 then error("secrets: at most 32 per step", 4) end
  tsort(names)
  return names
end

local function secrets_json(names)
  local parts = {}
  for i = 1, #names do parts[i] = '"' .. names[i] .. '"' end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- The artifacts of a step (DAT-003, docs/artifacts.md): `artifacts = { upload = { "dist/**" }, download = { "app" } }`. After the command has succeeded the shim
-- puts every file under /cicd/workspace that matches an `upload` pattern into the shard's object store; before the command starts it fetches what `download`
-- names (an artifact of the same run, a file or a directory) to the same place. The patterns are paths relative to the workspace with `*` (within a name),
-- `**` (across directories) and `?`. A job's declaration and a step's are added together. Returns a table or nil.
local ART_MAX = 32
local function norm_art_list(v, what, glob, depth)
  if v == nil then return nil end
  if type(v) ~= "table" then error("artifacts." .. what .. ": a list of paths", depth) end
  local out, seen = {}, {}
  for i = 1, rawlen(v) do
    local p = v[i]
    if type(p) ~= "string" or #p == 0 or #p > 256 or p:sub(1, 1) == "/" or p:find("%.%.") or p:find("[%c\\]") then
      error("artifacts." .. what .. ": a path inside the workspace (relative, no .., at most 256 characters)", depth)
    end
    if not glob and p:find("[%*%?]") then error("artifacts.download: a name or a directory, no wildcards", depth) end
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  if #out > ART_MAX then error("artifacts." .. what .. ": at most " .. ART_MAX .. " entries", depth) end
  tsort(out)
  return out
end

local function norm_artifacts(v, depth)
  if v == nil then return nil end
  if type(v) ~= "table" then error("artifacts: a table { upload = {...}, download = {...} }", depth) end
  for k in rawnext, v do
    if k ~= "upload" and k ~= "download" then error("artifacts: unknown field '" .. tostring_(k) .. "'", depth) end
  end
  return { upload = norm_art_list(v.upload, "upload", true, depth), download = norm_art_list(v.download, "download", false, depth) }
end

local function merge_art_list(a, b, what)
  if a == nil then return b end
  if b == nil then return a end
  local out, seen = {}, {}
  for k = 1, 2 do
    local l = (k == 1) and a or b
    for i = 1, #l do
      if not seen[l[i]] then seen[l[i]] = true; out[#out + 1] = l[i] end
    end
  end
  if #out > ART_MAX then error("artifacts." .. what .. ": at most " .. ART_MAX .. " entries", 4) end
  tsort(out)
  return out
end

local function merge_artifacts(a, b)
  if a == nil then return b end
  if b == nil then return a end
  return { upload = merge_art_list(a.upload, b.upload, "upload"), download = merge_art_list(a.download, b.download, "download") }
end

local function artifacts_json(a)
  local parts = {}
  for _, k in ipairs({ "download", "upload" }) do
    local l = a[k]
    if l and #l > 0 then
      local items = {}
      for i = 1, #l do items[i] = jstr(l[i]) end
      parts[#parts + 1] = '"' .. k .. '":[' .. table.concat(items, ",") .. "]"
    end
  end
  if #parts == 0 then return nil end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The execution profile of a job (RUN-004): "" is the organisation's ordinary one, "build" the build profile (A.13), whose steps run
-- as build Pods in the organisation's own namespace (D-42), and "deploy" the deploy profile (D-48): an ordinary step that may reach the
-- targets of a deployment (the Kubernetes API server, what the operator lists). Core refuses a profile that the shard does not have.
local function norm_profile(v)
  if v == nil or v == "default" then return "" end
  if v ~= "build" and v ~= "deploy" then error("ci.job: profile must be \"default\", \"build\" or \"deploy\"", 3) end
  return v
end

-- The cache of a step (DAT-004, docs/cache.md): `cache = { key = "deps-v1", paths = { "node_modules" }, restore_keys = { "deps-" } }`, or a list of such tables. Before the
-- command the shim restores the entry with the key, or else the latest whose key starts with a restore key; after a command that succeeded it saves the paths under the key,
-- unless the key was found (a key is immutable). A job's declaration and a step's are added together (the same key is the step's). Returns a list, or nil.
local CACHE_KEY_PAT = "^[%a%d%._:%+=@%%%-]+$"
local function cache_path_ok(p)
  if type(p) ~= "string" or #p < 1 or #p > 512 or p:sub(1, 1) == "/" or p:sub(-1) == "/" or p:find("[%c\\]") then return false end
  for part in (p .. "/"):gmatch("([^/]*)/") do
    if part == "" or part == "." or part == ".." then return false end
  end
  return true
end
local function norm_cache(v, depth)
  if v == nil then return nil end
  if type(v) ~= "table" then error("cache: a table { key = ..., paths = {...} }, or a list of them", depth) end
  local list = v
  if rawget(v, "key") ~= nil or rawget(v, "paths") ~= nil then list = { v } end
  local out = {}
  for i = 1, rawlen(list) do
    local e = list[i]
    if type(e) ~= "table" then error("cache: an entry is a table { key = ..., paths = {...} }", depth) end
    for k in rawnext, e do
      if k ~= "key" and k ~= "paths" and k ~= "restore_keys" then error("cache: unknown field '" .. tostring_(k) .. "' (key, paths, restore_keys)", depth) end
    end
    local key = e.key
    if type(key) ~= "string" or #key < 1 or #key > 200 or not key:match(CACHE_KEY_PAT) then
      error("cache: key is 1..200 characters: letters, digits and . _ : + = @ % - (no '/')", depth)
    end
    local paths = {}
    if type(e.paths) ~= "table" or rawlen(e.paths) < 1 or rawlen(e.paths) > 20 then error("cache: paths is a list of 1..20 files or directories of the workspace", depth) end
    for j = 1, rawlen(e.paths) do
      if not cache_path_ok(e.paths[j]) then error("cache: '" .. tostring_(e.paths[j]) .. "' is not a path inside the workspace (relative, no '..')", depth) end
      paths[j] = e.paths[j]
    end
    local rks = {}
    if e.restore_keys ~= nil then
      if type(e.restore_keys) ~= "table" or rawlen(e.restore_keys) > 5 then error("cache: restore_keys is a list of at most 5 key prefixes", depth) end
      for j = 1, rawlen(e.restore_keys) do
        local r = e.restore_keys[j]
        if type(r) ~= "string" or #r < 1 or #r > 200 or not r:match(CACHE_KEY_PAT) then error("cache: a restore key is a key prefix like a key", depth) end
        rks[j] = r
      end
    end
    out[#out + 1] = { key = key, paths = paths, restore_keys = rks }
  end
  if #out > 4 then error("cache: at most 4 caches per step", depth) end
  if #out == 0 then return nil end
  return out
end

local function merge_cache(a, b)
  if a == nil then return b end
  if b == nil then return a end
  local out = {}
  local byKey = {}
  for k = 1, 2 do
    local l = (k == 1) and a or b
    for i = 1, #l do
      local at = byKey[l[i].key]
      if at then out[at] = l[i] else out[#out + 1] = l[i]; byKey[l[i].key] = #out end
    end
  end
  if #out > 4 then error("cache: at most 4 caches per step", 4) end
  return out
end

local function cache_json(list)
  local parts = {}
  for i = 1, #list do
    local e = list[i]
    local ps, rs = {}, {}
    for j = 1, #e.paths do ps[j] = jstr(e.paths[j]) end
    for j = 1, #e.restore_keys do rs[j] = jstr(e.restore_keys[j]) end
    parts[i] = '{"key":' .. jstr(e.key) .. (e.mode and (',"mode":' .. jstr(e.mode)) or "") .. ',"paths":[' .. table.concat(ps, ",") .. '],"restore_keys":[' .. table.concat(rs, ",") .. "]}"
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- The environment a script gives to steps (VAR-004). Three places, from the lower to the higher: `ci.pipeline{ env = {...} }` and `ci.job{ env = {...} }` / `j:env{...}`
-- (together the "env of the job": the steps of the job get them as ordinary variables, above the launch parameters and below what a step writes to $CICD_ENV), and the
-- `env` option of one `Job:sh` (above $CICD_ENV: the step's own word). Values are text, numbers or booleans, shown as text; the core refuses a name that a step may not
-- set (STO-004). Returns a new table, or nil when nothing was given.
local ENV_MAX_COUNT, ENV_MAX_VALUE, ENV_MAX_TOTAL = 100, 8192, 65536
local pipeline_env = nil
local function norm_env(v, what, depth)
  if v == nil then return nil end
  if type(v) ~= "table" then error(what .. ": a table NAME = \"value\" expected", depth) end
  local out, n, total = {}, 0, 0
  for k, val in rawnext, v do
    if type(k) ~= "string" or #k > 64 or not k:match("^[A-Z_][A-Z0-9_]*$") then
      error(what .. ": a name is capital letters, digits and _, not starting with a digit, at most 64 characters", depth)
    end
    local t = type(val)
    if t == "number" then val = (mtype(val) == "integer") and format_("%d", val) or format_("%.14g", val)
    elseif t == "boolean" then val = val and "true" or "false"
    elseif t ~= "string" then error(what .. ": the value of " .. k .. " is a string, a number or a boolean", depth) end
    if #val > ENV_MAX_VALUE then error(what .. ": the value of " .. k .. " is longer than " .. ENV_MAX_VALUE .. " bytes", depth) end
    if val:find("[\0-\8\11\12\14-\31\127]") then error(what .. ": the value of " .. k .. " has a control character", depth) end
    n = n + 1
    total = total + #val
    out[k] = val
  end
  if n > ENV_MAX_COUNT then error(what .. ": at most " .. ENV_MAX_COUNT .. " variables", depth) end
  if total > ENV_MAX_TOTAL then error(what .. ": the values are at most " .. ENV_MAX_TOTAL .. " bytes in all", depth) end
  if n == 0 then return nil end
  return out
end

local function merge_env(a, b, what)
  if a == nil then return b end
  if b == nil then return a end
  local out, n, total = {}, 0, 0
  for k = 1, 2 do
    for name, val in rawnext, (k == 1) and a or b do out[name] = val end
  end
  for _, val in rawnext, out do n = n + 1; total = total + #val end
  if n > ENV_MAX_COUNT then error(what .. ": at most " .. ENV_MAX_COUNT .. " variables", 4) end
  if total > ENV_MAX_TOTAL then error(what .. ": the values are at most " .. ENV_MAX_TOTAL .. " bytes in all", 4) end
  return out
end

local function env_json(t)
  local names = {}
  for k in rawnext, t do names[#names + 1] = k end
  tsort(names)
  local parts = {}
  for i = 1, #names do parts[i] = jstr(names[i]) .. ":" .. jstr(t[names[i]]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The step's options reach the shim as one canonical JSON object (keys sorted, only what is set): "" when nothing is.
local function step_opts(job, opts)
  local metrics, mask, timeout = job.__metrics, job.__mask, job.__timeout
  local secrets = job.__secrets
  local artifacts = job.__artifacts
  local env, step_env = job.__env, nil
  local cache = job.__cache
  if opts then
    if opts.env ~= nil then step_env = norm_env(opts.env, "Job:sh env", 4) end
    if opts.cache ~= nil then cache = merge_cache(cache, norm_cache(opts.cache, 4)) end
    if opts.artifacts ~= nil then artifacts = merge_artifacts(artifacts, norm_artifacts(opts.artifacts, 4)) end
    if opts.secrets ~= nil then secrets = merge_secrets(secrets, norm_secrets(opts.secrets, 4)) end
    if opts.metrics ~= nil then metrics = norm_metrics(opts.metrics) end
    if opts.mask ~= nil then mask = norm_mask(opts.mask) end
    if opts.timeout ~= nil then timeout = norm_timeout(opts.timeout) end
  end
  local parts = {}
  local art = artifacts and artifacts_json(artifacts)
  if art then parts[#parts + 1] = '"artifacts":' .. art end
  if cache then parts[#parts + 1] = '"cache":' .. cache_json(cache) end
  if env then parts[#parts + 1] = '"env":' .. env_json(env) end
  if mask ~= "" then parts[#parts + 1] = '"mask":' .. mask end
  if metrics ~= "" then parts[#parts + 1] = '"metrics":' .. metrics end
  if secrets and #secrets > 0 then parts[#parts + 1] = '"secrets":' .. secrets_json(secrets) end
  if job.__shm then parts[#parts + 1] = '"shm":' .. jstr(job.__shm) end
  if step_env then parts[#parts + 1] = '"step_env":' .. env_json(step_env) end
  if timeout then parts[#parts + 1] = '"timeout":' .. timeout end
  if job.__workspace then parts[#parts + 1] = '"workspace":' .. jstr(job.__workspace) end
  if #parts == 0 then return "" end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The outputs of a step (STO-003): the text after the exit code in its answer is `name=value` lines (a backslash is \\ and a line break is \n in a value); a line that is not a pair is left out.
local function parse_outputs(text)
  local t = {}
  for name, value in text:gmatch("([A-Za-z_][A-Za-z0-9_]*)=([^\n]*)\n") do
    t[name] = value:gsub("\\(.)", function(c) if c == "n" then return "\n" end return c end)
  end
  return t
end

-- A step is a table that describes it and runs nothing: `step.sh["ab"]{ cmd = "make lint" }`, `step.cache_restore["c"]{ keys = {...} }`, `step.cache_save["d"]{ key = ..., paths = {...} }`.
-- The id is the index (D-67), so a step without one cannot be written; it is checked at once, with the line. A job runs its list of steps in order (`steps = { ... }`) or, for the logic
-- that needs a result of a step to go on (`body = function(j) ... end`), runs them one by one with `j:run(step)`. A step that fails (a code other than 0, unless `ignore_failure`) fails the job.
local STEP_FIELDS = {
  sh = { cmd = true, name = true, ignore_failure = true, capture = true, image = true, env = true, cache = true, artifacts = true, secrets = true, metrics = true, mask = true, timeout = true },
  cache_restore = { keys = true, name = true },
  cache_save = { key = true, paths = true, name = true },
}
local steps_made = setmetatable({}, { __mode = "k" })    -- the descriptions that the constructors made: a script cannot pass off a table of its own for one

local function check_name(v, what)
  if v ~= nil and (type(v) ~= "string" or #v == 0 or #v > 200) then error(what .. ": name is a text of 1 to 200 characters", 3) end
end

local function step_ctor(kind)
  local what = "step." .. kind
  return setmetatable({}, {
    __index = function(_, id)
      local sid = norm_ref(id, STEP_ID_WIDTH, what)
      return function(opts)
        if type(opts) ~= "table" then error(what .. "[\"" .. sid .. "\"]: a table of fields expected", 2) end
        for k in rawnext, opts do
          if not STEP_FIELDS[kind][k] then error(what .. "[\"" .. sid .. "\"]: unknown field '" .. tostring_(k) .. "'", 2) end
        end
        check_name(opts.name, what)
        if kind == "sh" then
          if type(opts.cmd) ~= "string" or opts.cmd == "" then error(what .. "[\"" .. sid .. "\"]: cmd is a command, a text", 2) end
        elseif kind == "cache_restore" then
          local keys = opts.keys
          if type(keys) ~= "table" or rawlen(keys) < 1 or rawlen(keys) > 6 then error(what .. ": keys is a list of 1 to 6 keys: the first is the key, the others are key prefixes", 2) end
        else
          if type(opts.key) ~= "string" then error(what .. ": key is a text", 2) end
        end
        local d = { kind = kind, id = sid, line = getline(), opts = opts }
        steps_made[d] = true
        return d
      end
    end,
    __call = function() error(what .. ": the id is the index: " .. what .. "[\"a\"]{ ... }", 2) end,
  })
end
local step = { sh = step_ctor("sh"), cache_restore = step_ctor("cache_restore"), cache_save = step_ctor("cache_save") }

-- the outputs of a step (STO-003) are parsed by `parse_outputs` above; the result of a step is { status = "ok"|"failed", code, outputs, stdout }
local function run_sh(job, d)
  local o = d.opts
  local line = d.line
  if o.ignore_failure ~= nil and type(o.ignore_failure) ~= "boolean" then error("step.sh: ignore_failure must be a boolean", 3) end
  local image = job.__image
  if o.image ~= nil then
    if type(o.image) ~= "string" or o.image == "" then error("step.sh: image is a non-empty string", 3) end
    image = o.image
  end
  -- payload: job key, image, profile ("" = the ordinary one), canonical options JSON ("" = none) and the command, tab-separated; the command is last because it may itself contain
  -- tabs (core splits into five fields)
  local no = job.__no * 1048576 + id_number(d.id)
  local code, out = call("job_sh", job.__key .. "\t" .. image .. "\t" .. job.__profile .. "\t" .. step_opts(job, o) .. "\t" .. o.cmd, line, no):match("^(%-?%d+)\n(.*)$")
  code = tonumber(code)
  -- a non-zero code fails the job (and so the run, unless the script catches the error); `ignore_failure = true` returns it instead. The code is in the journal, so a replay fails at the same call.
  if code ~= 0 and not o.ignore_failure then error("step failed with code " .. tostring(code) .. " (job " .. job.__key .. ", step " .. d.id .. ")", 3) end
  return { status = code == 0 and "ok" or "failed", code = code, outputs = parse_outputs(out), stdout = o.capture and out or nil }
end

-- `step.cache_restore` and `step.cache_save` of the API v1 signatures (lua/stdlib/cicd.d.lua): each is a step of its own in the job's Pod, on the run's workspace, so a script can restore a
-- cache in the middle of a job, or save one when it chooses. `keys` is the key and then the key prefixes to fall back on, as `restore_keys` of the `cache` option; the answer of a restore is
-- `{ hit = true, key = <the key restored> }` or `{ hit = false }`: the shim says which key it restored, the core puts that in the step's result (the journal), so a replay sees the same. A
-- restore that finds nothing is not an error; a save of a key that is stored already is not one either (a key is immutable). The job's image needs a shell (`true`).
local function run_cache(job, d)
  local decl
  if d.kind == "cache_restore" then
    local keys = d.opts.keys
    local rest = {}
    for i = 1, rawlen(keys) do
      local k = keys[i]
      if type(k) ~= "string" or #k < 1 or #k > 200 or not k:match(CACHE_KEY_PAT) then error("step.cache_restore: a key is 1..200 characters: letters, digits and . _ : + = @ % - (no '/')", 3) end
      if i > 1 then rest[i - 1] = k end
    end
    decl = { key = keys[1], mode = "restore", paths = {}, restore_keys = rest }
  else
    local list = norm_cache({ key = d.opts.key, paths = d.opts.paths }, 3)
    decl = list[1]
    decl.mode = "save"
  end
  local only = { __key = job.__key, __image = job.__image, __profile = job.__profile, __metrics = "", __mask = job.__mask, __timeout = job.__timeout, __env = job.__env, __cache = { decl }, __workspace = job.__workspace }
  local no = job.__no * 1048576 + id_number(d.id)
  local code, out = call("job_sh", job.__key .. "\t" .. job.__image .. "\t" .. job.__profile .. "\t" .. step_opts(only, nil) .. "\t" .. "true", d.line, no):match("^(%-?%d+)\n(.*)$")
  code = tonumber(code)
  if code ~= 0 then error("step failed with code " .. tostring(code) .. " (job " .. job.__key .. ", step " .. d.id .. ")", 3) end
  if d.kind == "cache_save" then return { status = "ok", code = 0, outputs = {} } end
  if out == "" then return { status = "ok", code = 0, outputs = {}, hit = false } end
  return { status = "ok", code = 0, outputs = {}, hit = true, key = out }
end

local Job_mt = { __index = {
  -- `j:env{ NAME = "value" }`: variables for the steps of this job that follow (no Pod is started); the env of the job in VAR-004
  env = function(self, tbl)
    if type(tbl) ~= "table" then error("Job:env: a table NAME = \"value\" expected", 2) end
    self.__env = merge_env(self.__env, norm_env(tbl, "Job:env", 3), "Job:env")
  end,
  -- `j:run(step)`: runs a step that a constructor of `step` described, and returns its result (`steps` of the job's result has it too, by its id)
  run = function(self, d)
    if type(d) ~= "table" or not steps_made[d] then error("Job:run: a step made by step.sh[\"id\"]{ ... } expected", 2) end
    local first = self.__step_ids[d.id]
    if first then error("duplicate_id: the step id '" .. d.id .. "' is used in the job '" .. self.__key .. "' at line " .. first .. " and again at line " .. d.line, 0) end
    self.__step_ids[d.id] = d.line
    step_count = step_count + 1
    if step_count > MAX_STEPS then error("step_limit: a run has at most " .. MAX_STEPS .. " steps; the step at line " .. d.line .. " is the " .. step_count .. "th", 0) end
    local r
    if d.kind == "sh" then r = run_sh(self, d) else r = run_cache(self, d) end
    self.__results[d.id] = r
    return r
  end,
  sh = function() error("Job:sh is gone (D-67): a step is described by step.sh[\"ab\"]{ cmd = \"make\" }, in the list `steps` of the job or run by j:run(...)", 2) end,
} }

-- Launch parameters (PIP-012, VAR-002). The script declares them in `ci.pipeline{ params = { NAME = ci.string{...}, ... } }`; the names are the names of
-- environment variables (VAR-003). The values given when the run was started arrive as text (`given`); they are checked against the declarations and
-- completed with the defaults, and the result is journaled once, as a `params` host call: core keeps it with the run and gives it to every step as
-- ordinary environment variables, and a replay gets the same values from the journal. `run.params` holds them typed.
local PARAM_KINDS = { string = true, number = true, bool = true, choice = true }
local PARAM_FIELDS = {
  string = { default = true, required = true, max_length = true, pattern = true, description = true },
  number = { default = true, required = true, min = true, max = true, integer = true, description = true },
  bool = { default = true, required = true, description = true },
  choice = { default = true, required = true, description = true },
}
local PARAM_MAX_VALUE, PARAM_MAX_TOTAL, PARAM_MAX_COUNT = 1024, 4096, 64

-- `ci.string{...}`, `ci.number{...}`, `ci.bool{...}`, and `ci.choice({"a", "b"}, {...})` as in the API v1 signatures (lua/stdlib/cicd.d.lua)
local function param_ctor(kind)
  return function(a, b)
    local spec, choices = a, nil
    if kind == "choice" then
      choices, spec = a, b
      if type(choices) ~= "table" or rawlen(choices) == 0 or rawlen(choices) > 64 then error("ci.choice: the first argument is a list of 1..64 strings", 2) end
      for i = 1, rawlen(choices) do
        if type(choices[i]) ~= "string" or #choices[i] == 0 or #choices[i] > PARAM_MAX_VALUE then error("ci.choice: the choices are non-empty strings", 2) end
      end
    end
    if spec == nil then spec = {} end
    if type(spec) ~= "table" then error("ci." .. kind .. ": a table of options expected", 2) end
    for k in rawnext, spec do
      if not PARAM_FIELDS[kind][k] then error("ci." .. kind .. ": unknown field '" .. tostring_(k) .. "'", 2) end
    end
    if spec.required ~= nil and type(spec.required) ~= "boolean" then error("ci." .. kind .. ": required must be a boolean", 2) end
    if spec.pattern ~= nil then
      if type(spec.pattern) ~= "string" or #spec.pattern > 128 or not pcall(string.find, "", spec.pattern) then error("ci.string: pattern must be a valid Lua pattern of at most 128 characters", 2) end
    end
    return { __param = kind, spec = spec, choices = choices }
  end
end

local function param_text(kind, v)
  if kind == "bool" then return v and "true" or "false" end
  if kind == "number" then
    if mtype(v) == "integer" then return format_("%d", v) end
    return format_("%.14g", v)
  end
  return tostring_(v)
end

-- the text form of a value of the declared kind, or nil and the reason; `what` names the parameter in messages
local function param_check(name, d, text)
  local kind, sp = d.__param, d.spec
  if #text > PARAM_MAX_VALUE then return nil, "parameter " .. name .. " is longer than " .. PARAM_MAX_VALUE .. " bytes" end
  if text:find("[%c]") then return nil, "parameter " .. name .. " has a control character" end
  if kind == "string" then
    if sp.max_length and #text > sp.max_length then return nil, "parameter " .. name .. " is longer than " .. sp.max_length end
    if sp.pattern and not text:find("^" .. sp.pattern .. "$") then return nil, "parameter " .. name .. " does not match " .. sp.pattern end
    return text
  elseif kind == "number" then
    local n = tonumber(text)
    if n == nil or n ~= n or n == math.huge or n == -math.huge or not text:match("^%s*%-?[%d%.eE%+%-]+%s*$") then
      return nil, "parameter " .. name .. " must be a number"
    end
    if sp.integer then
      if n ~= math.floor(n) then return nil, "parameter " .. name .. " must be an integer" end
      n = math.tointeger(n) or n
    end
    if sp.min ~= nil and n < sp.min then return nil, "parameter " .. name .. " must be at least " .. param_text("number", sp.min) end
    if sp.max ~= nil and n > sp.max then return nil, "parameter " .. name .. " must be at most " .. param_text("number", sp.max) end
    return param_text("number", n)
  elseif kind == "bool" then
    if text ~= "true" and text ~= "false" then return nil, "parameter " .. name .. " must be true or false" end
    return text
  end
  for i = 1, rawlen(d.choices) do
    if d.choices[i] == text then return text end
  end
  return nil, "parameter " .. name .. " must be one of: " .. table.concat(d.choices, ", ")
end

local function param_typed(kind, text)
  if kind == "number" then return tonumber(text) end
  if kind == "bool" then return text == "true" end
  return text
end

-- returns the typed table, the canonical JSON ("" = none) or raises a script error
local function resolve_params(decls, given)
  decls = decls or {}
  local names = {}
  for k, d in rawnext, decls do
    if type(k) ~= "string" or #k > 64 or not k:match("^[A-Z_][A-Z0-9_]*$") then
      error("params: a name is capital letters, digits and _, not starting with a digit, at most 64 characters", 0)
    end
    if type(d) ~= "table" or not PARAM_KINDS[rawget(d, "__param") or ""] then
      error("params." .. k .. ": declare it with ci.string, ci.number, ci.bool or ci.choice", 0)
    end
    names[#names + 1] = k
  end
  if #names > PARAM_MAX_COUNT then error("params: at most " .. PARAM_MAX_COUNT .. " parameters", 0) end
  for k in rawnext, given do
    if decls[k] == nil then error("unknown parameter " .. tostring_(k) .. " (the pipeline declares: " .. (#names > 0 and table.concat(names, ", ") or "none") .. ")", 0) end
  end
  tsort(names)
  local typed, parts, total = {}, {}, 0
  for i = 1, #names do
    local name = names[i]
    local d = decls[name]
    local text = given[name]
    if text == nil and d.spec.default ~= nil then
      local dk = d.__param
      if (dk == "number" and type(d.spec.default) ~= "number") or (dk == "bool" and type(d.spec.default) ~= "boolean")
         or ((dk == "string" or dk == "choice") and type(d.spec.default) ~= "string") then
        error("params." .. name .. ": the default is not a " .. dk, 0)
      end
      text = param_text(dk, d.spec.default)
    end
    if text == nil then
      if d.spec.required then error("parameter " .. name .. " is required", 0) end
    else
      local ok, why = param_check(name, d, text)
      if not ok then error(why, 0) end
      typed[name] = param_typed(d.__param, ok)
      parts[#parts + 1] = jstr(name) .. ":" .. jstr(ok)
      total = total + #name + #ok
    end
  end
  if total > PARAM_MAX_TOTAL then error("the parameters are longer than " .. PARAM_MAX_TOTAL .. " bytes in all", 0) end
  return typed, (#parts > 0) and ("{" .. table.concat(parts, ",") .. "}") or ""
end

-- `b58x(n)` and `b58xx(n)`: pure functions (not journaled) that write the integer n as exactly one or exactly two characters of the Base58 alphabet of Bitcoin (digits
-- and letters without 0, O, I, l, which are mistaken for one another): `b58x` 0 to 57, `b58xx` 0 to 3363, of which a run needs 200 at most. A number that does not fit is an
-- error, never a longer result. The alphabet is in the order of the characters' codes, so results of one function sort like the numbers. For ids built in loops, which are at
-- most 8 characters of letters and digits (docs/parallel.md section 3.3): "a" .. b58xx(i) .. b58xx(j) .. b58xx(k) is 7.
local B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local function b58_digits(name, n, width)
  if type(n) ~= "number" or n % 1 ~= 0 then error(name .. ": an integer expected, got " .. tostring_(n), 3) end
  local top = math.tointeger(58 ^ width) - 1
  local given = n
  n = math.tointeger(n)
  if n == nil or n < 0 or n > top then error(name .. ": " .. tostring_(given) .. " does not fit " .. width .. " character(s) (0 to " .. top .. ")", 3) end
  local out = {}
  for i = width, 1, -1 do
    local d = n % 58
    out[i] = string.sub(B58, d + 1, d + 1)
    n = n // 58
  end
  return table.concat(out)
end
G.b58x = function(n) return b58_digits("b58x", n, 1) end
G.b58xx = function(n) return b58_digits("b58xx", n, 2) end      -- globals of their own, not members of `ci`: plain helpers of the script

-- `b58f(format, ...)`: an id built from a format in which every number shows how many characters it takes. `{x}` is one character of Base58 (`b58x`), `{xx}` two (`b58xx`);
-- any other character of the format is a letter or digit and stands for itself: b58f("a{xx}{xx}{xx}", i, j, k) is "a" .. b58xx(i) .. b58xx(j) .. b58xx(k). The format is
-- checked as a whole, before a number is looked at: at most 8 characters, a letter first, only these placeholders, as many arguments as placeholders (docs/parallel.md
-- section 3.3). Pure, not journaled.
function b58f(fmt, ...)
  if type(fmt) ~= "string" then error("b58f: the format is a string, got " .. type(fmt), 2) end
  local parts, size, i = {}, 0, 1
  while i <= #fmt do
    local c = string.sub(fmt, i, i)
    if c == "{" then
      local close = string.find(fmt, "}", i, true)
      local name = close and string.sub(fmt, i + 1, close - 1)
      if name ~= "x" and name ~= "xx" then error("b58f: at position " .. i .. " of the format only {x} and {xx} are placeholders", 2) end
      parts[#parts + 1] = #name
      size = size + #name
      i = close + 1
    elseif string.find(c, "^[A-Za-z0-9]$") then
      parts[#parts + 1] = c
      size = size + 1
      i = i + 1
    else
      error("b58f: at position " .. i .. " of the format a letter, a digit, {x} or {xx} is expected", 2)
    end
  end
  if type(parts[1]) ~= "string" or not string.find(parts[1], "^[A-Za-z]$") then error("b58f: an id starts with a letter, and the format does not", 2) end
  if size > 8 then error("b58f: the format makes " .. size .. " characters, an id is at most 8", 2) end
  local slots = 0
  for _, p in ipairs(parts) do if type(p) == "number" then slots = slots + 1 end end
  if select("#", ...) ~= slots then error("b58f: the format has " .. slots .. " placeholder(s) and " .. select("#", ...) .. " argument(s)", 2) end
  local args, out, k = { ... }, {}, 0
  for _, p in ipairs(parts) do
    if type(p) == "number" then
      k = k + 1
      local ok, r = pcall(b58_digits, "b58f", args[k], p)
      if not ok then error("b58f: argument " .. k .. ": " .. tostring_(r), 2) end
      out[#out + 1] = r
    else
      out[#out + 1] = p
    end
  end
  return table.concat(out)
end

-- `b32f(format, ...)` (D-67): an id built from loop variables in the alphabet of Crockford, lowercase (`0123456789abcdefghjkmnpqrstvwxyz`: the digits and the letters but i l o u, in the
-- order of their codes, so that results of one width sort like the numbers). `{x}` is one character (0 to 31), `{xx}` two (0 to 1023), `{xxx}` three (0 to 32767), `{xxxx}` four
-- (0 to 1048575), in any combination, one argument to each: b32f("{x}{x}{x}", i, j, k) is three characters. A letter or a digit of the alphabet in the format stands for itself.
-- The result is exactly the characters of the format and pads nothing (a short id is padded by the rule of every id), and it is at most 4 characters, the width of a step's id. The format
-- is checked as a whole before any number is looked at; a number that does not fit its placeholder is an error, never a longer or a shorter result. Pure, not journaled.
local B32 = "0123456789abcdefghjkmnpqrstvwxyz"
local function b32_digits(n, width)
  local out = {}
  for i = width, 1, -1 do
    local d = n % 32
    out[i] = string.sub(B32, d + 1, d + 1)
    n = n // 32
  end
  return table.concat(out)
end

function b32f(fmt, ...)
  if type(fmt) ~= "string" then error("b32f: the format is a string, got " .. type(fmt), 2) end
  if #fmt == 0 then error("b32f: the format is empty", 2) end
  local parts, size, i = {}, 0, 1
  while i <= #fmt do
    local c = string.sub(fmt, i, i)
    if c == "{" then
      local close = string.find(fmt, "}", i, true)
      local name = close and string.sub(fmt, i + 1, close - 1)
      if not name or not string.find(name, "^x+$") or #name > 4 then
        error("b32f: at position " .. i .. " of the format only {x}, {xx}, {xxx} and {xxxx} are placeholders" .. (name and (", not {" .. name .. "}") or ""), 2)
      end
      parts[#parts + 1] = #name
      size = size + #name
      i = close + 1
    else
      local l = string.lower(c)
      if not string.find(B32, l, 1, true) then
        error("b32f: at position " .. i .. " of the format the character '" .. c .. "' is not in the alphabet of ids (digits and the letters but i, l, o, u)", 2)
      end
      parts[#parts + 1] = l
      size = size + 1
      i = i + 1
    end
  end
  if size > 4 then error("b32f: the format makes " .. size .. " characters, an id is at most 4 (a step's)", 2) end
  local slots = 0
  for _, p in ipairs(parts) do if type(p) == "number" then slots = slots + 1 end end
  if select("#", ...) ~= slots then error("b32f: the format has " .. slots .. " placeholder(s) and " .. select("#", ...) .. " argument(s)", 2) end
  local args, out, k = { ... }, {}, 0
  for _, p in ipairs(parts) do
    if type(p) == "number" then
      k = k + 1
      local given = args[k]
      if type(given) ~= "number" or given % 1 ~= 0 then error("b32f: argument " .. k .. ": an integer expected, got " .. tostring_(given), 2) end
      local top = math.tointeger(32 ^ p) - 1
      local n = math.tointeger(given)
      if n == nil or n < 0 or n > top then error("b32f: argument " .. k .. ": " .. tostring_(given) .. " does not fit " .. p .. " character(s) (0 to " .. top .. ")", 2) end
      out[#out + 1] = b32_digits(n, p)
    else
      out[#out + 1] = p
    end
  end
  return table.concat(out)
end

-- `ci.parallel(branches, opts)` (docs/parallel.md sections 2 and 5): each branch is a coroutine of this Lua state, in the order of the names. A branch runs until it ends or makes a host
-- call; the call is handed up (to Nim, or to the scheduler of the ci.parallel the branch is nested in) and, if it is answered, the branch goes on at once; if it is pending the branch
-- parks and the next one starts or goes on. Nothing a parked branch waits for can change inside this execution, so it is not asked again: when no branch can go on, the run waits
-- (`park`) and is led again, by replay, when a step has ended. `max_parallel` is the number of branches started and not ended at a time; the next to start is always the first that has
-- not, in the order of the names, so the set of calls does not depend on timing either. The result is a table name -> { ok = true, value = ... } or { ok = false, error = "..." }.
local MAX_BRANCHES, MAX_DEPTH = 1000, 10      -- the nesting is 10 levels (D-67): GitHub's reusable workflows go 10 deep, GitLab's child pipelines 2
local PARALLEL_FIELDS = { max_parallel = true, keep_going = true, fail_fast = true }

local function plain(v, depth)
  local t = type(v)
  if v == nil or t == "string" or t == "number" or t == "boolean" then return true end
  if t ~= "table" or depth > 16 or getmetatable(v) ~= nil then return false end
  for k, x in rawnext, v do
    local tk = type(k)
    if not (tk == "string" or tk == "number" or tk == "boolean") or not plain(x, depth + 1) then return false end
  end
  return true
end

-- `ci.matrix{ axes, include, exclude, max_parallel, fail_fast }` (PIP-009, lua/stdlib/cicd.d.lua): pure, not journaled. The combinations of the axes (sorted by name, the values in the
-- order given), without those an `exclude` entry matches in all its keys, and with the `include` ones that are not there; at most 200, checked at the call. The result is a list
-- of tables axis -> value; `ci.parallel(list, fn, opts)` makes a branch of each, named `arch=amd64,os=linux` (the keys sorted), with the combination as its argument, and takes
-- `max_parallel` and `fail_fast` of the matrix unless its own options give them. A value is a string (1 to 64 characters, no control character and none of , = [ ]), a number or a boolean.
local matrices = setmetatable({}, { __mode = "k" })          -- the list that ci.matrix made -> its max_parallel and fail_fast
local AXIS_PAT = "^[A-Za-z_][A-Za-z0-9_]*$"

local function scalar_text(v, what)
  local t = type(v)
  if t == "number" then return (mtype(v) == "integer") and format_("%d", v) or format_("%.14g", v) end
  if t == "boolean" then return v and "true" or "false" end
  if t == "string" then
    if #v < 1 or #v > 64 or v:find("[%c,=%[%]]") then error(what .. ": a string value is 1 to 64 characters, with no control character and none of , = [ ]", 4) end
    return v
  end
  error(what .. ": a value is a string, a number or a boolean", 4)
end

local function combo_label(c, what)
  local keys = {}
  for k in rawnext, c do
    if type(k) ~= "string" or not k:match(AXIS_PAT) then error(what .. ": a combination is a table axis = value; '" .. tostring_(k) .. "' is not an axis name", 3) end
    keys[#keys + 1] = k
  end
  if #keys == 0 then error(what .. ": a combination has at least one axis", 3) end
  tsort(keys)
  local parts = {}
  for i = 1, #keys do parts[i] = keys[i] .. "=" .. scalar_text(c[keys[i]], what .. " " .. keys[i]) end
  return table.concat(parts, ",")
end

local function matches(c, pattern)
  for k, v in rawnext, pattern do
    if c[k] ~= v then return false end
  end
  return true
end

local function matrix(spec)
  if type(spec) ~= "table" then error("ci.matrix: a table { axes = {...}, include = {...}, exclude = {...} } expected", 2) end
  for k in rawnext, spec do
    if k ~= "axes" and k ~= "include" and k ~= "exclude" and k ~= "max_parallel" and k ~= "fail_fast" then error("ci.matrix: unknown field '" .. tostring_(k) .. "'", 2) end
  end
  if spec.max_parallel ~= nil and not (mtype(spec.max_parallel) == "integer" and spec.max_parallel >= 1) then error("ci.matrix: max_parallel is a whole number of at least 1", 2) end
  if spec.fail_fast ~= nil and type(spec.fail_fast) ~= "boolean" then error("ci.matrix: fail_fast must be a boolean", 2) end
  local axes = spec.axes
  if type(axes) ~= "table" then error("ci.matrix: axes = { name = { values } } expected", 2) end
  local names = {}
  for k, vals in rawnext, axes do
    if type(k) ~= "string" or not k:match(AXIS_PAT) then error("ci.matrix: an axis name is letters, digits and _, not starting with a digit", 2) end
    if type(vals) ~= "table" or rawlen(vals) < 1 or rawlen(vals) > MAX_BRANCHES then error("ci.matrix: the axis " .. k .. " is a list of 1 to " .. MAX_BRANCHES .. " values", 2) end
    local seen = {}
    for i = 1, rawlen(vals) do
      local t = scalar_text(vals[i], "ci.matrix: the axis " .. k)
      if seen[t] then error("ci.matrix: the axis " .. k .. " has the value " .. t .. " twice", 2) end
      seen[t] = true
    end
    names[#names + 1] = k
  end
  if #names == 0 then error("ci.matrix: axes has at least one axis", 2) end
  tsort(names)
  local size = 1
  for i = 1, #names do
    size = size * rawlen(axes[names[i]])
    if size > 10000 then error("ci.matrix: the axes make more than 10000 combinations; at most " .. MAX_BRANCHES .. " are allowed", 2) end
  end
  local list = { {} }
  for i = 1, #names do
    local axis, vals, next_list = names[i], axes[names[i]], {}
    for _, c in ipairs(list) do
      for v = 1, rawlen(vals) do
        local copy = {}
        for k2, x in rawnext, c do copy[k2] = x end
        copy[axis] = vals[v]
        next_list[#next_list + 1] = copy
      end
    end
    list = next_list
  end
  local function entries(what, v)
    if v == nil then return {} end
    if type(v) ~= "table" then error("ci.matrix: " .. what .. " is a list of tables axis = value", 3) end
    for i = 1, rawlen(v) do
      if type(v[i]) ~= "table" then error("ci.matrix: " .. what .. " is a list of tables axis = value", 3) end
      combo_label(v[i], "ci.matrix " .. what)
    end
    return v
  end
  local excl = entries("exclude", spec.exclude)
  local kept = {}
  for _, c in ipairs(list) do
    local drop = false
    for i = 1, rawlen(excl) do if matches(c, excl[i]) then drop = true break end end
    if not drop then kept[#kept + 1] = c end
  end
  local present = {}
  for i = 1, #kept do present[combo_label(kept[i], "ci.matrix")] = true end
  local incl = entries("include", spec.include)
  for i = 1, rawlen(incl) do
    local label = combo_label(incl[i], "ci.matrix include")
    if not present[label] then
      present[label] = true
      local copy = {}
      for k, x in rawnext, incl[i] do copy[k] = x end
      kept[#kept + 1] = copy
    end
  end
  if #kept > MAX_BRANCHES then error("ci.matrix: " .. #kept .. " combinations; at most " .. MAX_BRANCHES .. " are allowed", 2) end
  matrices[kept] = { max_parallel = spec.max_parallel, fail_fast = spec.fail_fast }
  return kept
end

local function run_parallel(entries, opts)
  opts = opts or {}
  for k in rawnext, opts do
    if not PARALLEL_FIELDS[k] then error("ci.parallel: unknown option '" .. tostring_(k) .. "'", 2) end
  end
  for _, f in ipairs({ "keep_going", "fail_fast" }) do
    if opts[f] ~= nil and type(opts[f]) ~= "boolean" then error("ci.parallel: " .. f .. " must be a boolean", 2) end
  end
  if opts.max_parallel ~= nil and not (mtype(opts.max_parallel) == "integer" and opts.max_parallel >= 1) then
    error("ci.parallel: max_parallel is a whole number of at least 1", 2)
  end
  local pctx = cur
  if pctx.depth >= MAX_DEPTH then error("ci.parallel: nesting is at most " .. MAX_DEPTH .. " levels", 2) end
  local n = #entries
  if n > MAX_BRANCHES then error("ci.parallel: at most " .. MAX_BRANCHES .. " branches", 2) end
  local br = {}
  for i = 1, n do br[i] = { key = entries[i].key, label = entries[i].label, fn = entries[i].fn, state = "new" } end
  pctx.pars = pctx.pars + 1
  local base = pctx.path .. ".p" .. pctx.pars
  for i = 1, n do br[i].ctx = new_ctx(base .. "[" .. br[i].label .. "]", pctx.depth + 1) end
  local maxp = opts.max_parallel or n
  local active, finished = 0, 0
  pctx.live = br                          -- for the decision of a ci.parallel above this one: which steps of these branches are in flight

  local function settle(b, ok, r)
    b.state = "done"
    active = active - 1
    finished = finished + 1
    if ok then
      if plain(r, 0) then b.ok, b.value = true, r
      else b.ok, b.error = false, "ci.parallel: branch '" .. b.label .. "' returned a value that is not plain data" end
      return
    end
    local msg = type(r) == "string" and r or safe_tostring(r)
    -- a limit of the run is the run's error, not a branch's result: the whole run ends with it
    if msg:find("duplicate_id:", 1, true) or msg:find("step_limit:", 1, true) then error(msg, 0) end
    b.ok, b.error = false, msg
  end

  local function cancel(b)                -- the branch is over, cancelled: it is never resumed (a started one holds a place until now)
    if b.state ~= "new" then active = active - 1 end
    b.state, b.ok, b.error, b.canceled, b.co = "done", false, "canceled", true, nil
    finished = finished + 1
  end

  local function drive(b, ans)            -- b runs until it ends or parks
    while true do
      local saved = cur
      cur = b.ctx
      local ok, r = cresume(b.co, ans)
      cur = saved
      if not ok then return settle(b, false, r) end
      if cstatus(b.co) == "dead" then return settle(b, true, r) end
      if r.kind == "__park" then b.state = "parked" return end
      if r.kind == "__canceled" then
        -- a step of this branch (or of one nested in it) was cancelled by the decision of the ci.parallel at path r.by. If that is this one the branch is cancelled; if it is above,
        -- the whole branch that holds this ci.parallel is over, and this coroutine ends here by telling the scheduler above
        if r.by == base or running() == state.main then return cancel(b) end
        yield_({ kind = "__canceled", by = r.by })
      end
      if r.ctx == b.ctx.path then b.req = r end
      -- a call of the branch (or of a branch of a ci.parallel nested in it): on to Nim or to the scheduler above. The answer is a result, or nil when the call is pending; the
      -- branch is resumed with either and parks itself on nil (`call`, or the scheduler nested in it), so a nested scheduler goes on with its other branches
      if running() == state.main then ans = yield_(r.kind, r.payload, r.line, r.ctx, r.nth) else ans = yield_(r) end
    end
  end

  -- fail_fast (docs/parallel.md section 6): the decision, once taken, is in the journal (`par_cancel`), and a replay follows it: the branches it left unstarted are not started, whatever
  -- the slots would allow now that more of the journal is known
  local notStarted = {}
  if opts.fail_fast then
    local decided = raw_call("par_peek", base, base)
    if decided ~= "" then for label in decided:sub(3):gmatch("[^\t]+") do notStarted[label] = true end end
  end
  for i = 1, n do
    local b = br[i]
    if notStarted[b.label] then
      cancel(b)
    elseif active < maxp then
      b.state = "ready"
      active = active + 1
      b.co = cocreate(b.fn)
      branch_co[b.co] = true
      drive(b, nil)
    end
  end

  if opts.fail_fast and finished < n then
    local first
    for i = 1, n do if br[i].state == "done" and not br[i].ok and not br[i].canceled then first = br[i] break end end
    if first then
      local steps, unstarted = {}, {}
      local function collect(b)
        if b.ctx.live then
          for k = 1, #b.ctx.live do if b.ctx.live[k].state == "parked" then collect(b.ctx.live[k]) end end
        elseif b.req and b.req.kind == "job_sh" then
          steps[#steps + 1] = b.req.ctx .. "\t" .. b.req.line .. "\t" .. b.req.nth
        end
      end
      for i = 1, n do
        if br[i].state == "new" then unstarted[#unstarted + 1] = br[i].label
        elseif br[i].state == "parked" then collect(br[i]) end
      end
      raw_call("par_cancel", base .. "\n" .. first.label .. "\n" .. table.concat(unstarted, "\t") .. (#steps > 0 and ("\n" .. table.concat(steps, "\n")) or ""), base)
      for i = 1, n do if br[i].state ~= "done" then cancel(br[i]) end end
    end
  end
  if finished < n then park() end         -- some branch waits, and nothing can go on: the run waits (never comes back in this execution)
  pctx.live = nil

  local results, failed, canceled = {}, {}, {}
  for i = 1, n do
    local b = br[i]
    if b.ok then results[b.key] = { ok = true, value = b.value }
    elseif b.canceled then results[b.key] = { ok = false, error = "canceled", canceled = true }; canceled[#canceled + 1] = b.label
    else results[b.key] = { ok = false, error = b.error }; failed[#failed + 1] = b.label end
  end
  if (#failed > 0 or #canceled > 0) and not opts.keep_going then
    local text = "parallel: branches failed: " .. table.concat(failed, ", ")
    for i = 1, n do
      if br[i].state == "done" and not br[i].ok and not br[i].canceled then
        local why = br[i].error
        if #why > 300 then why = why:sub(1, 300) .. "..." end
        text = text .. " (" .. br[i].label .. ": " .. why .. ")"
        break
      end
    end
    if #canceled > 0 then text = text .. "; canceled: " .. table.concat(canceled, ", ") end
    error(text, 2)
  end
  return results
end

-- `ci.parallel(branches, opts)`: branches is a table name = function (or a list of functions); `ci.parallel(combinations, fn, opts)`: a list of combinations (`ci.matrix`) and the function
-- every branch runs with its combination.
local function parallel(spec, a, b)
  if type(spec) ~= "table" then error("ci.parallel: a table of branches expected (name = function, or a list of functions)", 2) end
  local fn, opts = nil, a
  if type(a) == "function" then fn, opts = a, b end
  if opts ~= nil and type(opts) ~= "table" then error("ci.parallel: the options are a table", 2) end
  local entries = {}
  if fn then
    local n = rawlen(spec)
    for k in rawnext, spec do
      if not (mtype(k) == "integer" and k >= 1 and k <= n) then error("ci.parallel: with a function the first argument is a list of combinations (ci.matrix)", 2) end
    end
    if n > MAX_BRANCHES then error("ci.parallel: at most " .. MAX_BRANCHES .. " branches", 2) end
    local seen = {}
    for i = 1, n do
      local c = spec[i]
      if type(c) ~= "table" then error("ci.parallel: with a function the first argument is a list of combinations (ci.matrix)", 2) end
      local label = combo_label(c, "ci.parallel")
      if seen[label] then error("ci.parallel: the combination " .. label .. " is in the list twice", 2) end
      seen[label] = true
      entries[i] = { key = label, label = label, fn = function() return fn(c) end }
    end
    local d = matrices[spec]
    if d then
      local merged = {}
      if opts then for k, v in rawnext, opts do merged[k] = v end end
      for _, f in ipairs({ "max_parallel", "fail_fast" }) do
        if merged[f] == nil then merged[f] = d[f] end
      end
      opts = merged
    end
  else
    for k, f in stable_pairs(spec) do
      local label
      if mtype(k) == "integer" then label = tostring_(k)
      elseif type(k) == "string" then label = check_branch(k, "ci.parallel: a branch name"); label = k
      else error("ci.parallel: a branch is named by a string or is a place in a list", 2) end
      if type(f) ~= "function" then error("ci.parallel: branch '" .. label .. "' is not a function", 2) end
      entries[#entries + 1] = { key = k, label = label, fn = f }
      if #entries > MAX_BRANCHES then error("ci.parallel: at most " .. MAX_BRANCHES .. " branches", 2) end
    end
  end
  return run_parallel(entries, opts)
end

local JOB_FIELDS = { name = true, image = true, profile = true, metrics = true, mask = true, timeout = true, workspace = true, shm = true, secrets = true, artifacts = true, env = true, cache = true, lock = true, steps = true, body = true }
local finals = {}                       -- the cleanups of `ci.finally`, in the order registered
-- ci.trigger(path, opts) or ci.trigger{ project, path, ref, approval, params } (D-93): starts a pipeline as a run of its own and returns its id at once (it does not wait): the one at `path` of this run's
-- repository, at this run's commit and ref, or, with `project` (a project of the organisation, as Jenkins names a job), that project's repository at `ref`.
-- `opts.approval = true | { timeout = "24h" }` makes that run wait, holding nothing, for the approvals its project asks for; `opts.params` are its launch parameters.
local function trigger_timeout(v)
  if mtype(v) == "integer" or (type(v) == "number" and v == v // 1) then return math.tointeger(v) end
  if type(v) == "string" then
    local n, unit = v:match("^(%d+)([smhd])$")
    if n then return tonumber(n) * ({ s = 1, m = 60, h = 3600, d = 86400 })[unit] end
  end
  error("ci.trigger: approval.timeout is whole seconds or a string like \"30m\", \"24h\", \"2d\"", 3)
end
local function trigger(first, opts)
  local path
  if type(first) == "table" and opts == nil then opts, path = first, first.path
  else path = first end
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then error("ci.trigger: the options are a table { project = ..., path = ..., ref = ..., approval = ..., params = ... }", 2) end
  for k in stable_pairs(opts) do
    if k ~= "approval" and k ~= "params" and k ~= "project" and k ~= "path" and k ~= "ref" then error("ci.trigger: unknown option '" .. tostring_(k) .. "' (project, path, ref, approval, params)", 2) end
  end
  if path ~= nil and (type(path) ~= "string" or path == "") then error("ci.trigger: path is the path of a pipeline in the repository, for example \".ci/deploy.lua\"", 2) end
  if opts.project ~= nil and (type(opts.project) ~= "string" or opts.project == "") then error("ci.trigger: project is the path of a project of the organisation, for example \"team/deploy\"", 2) end
  if opts.ref ~= nil and (type(opts.ref) ~= "string" or opts.ref == "") then error("ci.trigger: ref is a branch, a tag or a commit", 2) end
  if path == nil and opts.project == nil then error("ci.trigger: the path of a pipeline in this repository, or a project, is expected, for example ci.trigger(\".ci/deploy.lua\")", 2) end
  local out = { "{" }
  local first_field = true
  local function field(text) out[#out + 1] = (first_field and "" or ",") .. text; first_field = false end
  if path ~= nil then field('"path":' .. jstr(path)) end
  if opts.project ~= nil then field('"project":' .. jstr(opts.project)) end
  if opts.ref ~= nil then field('"ref":' .. jstr(opts.ref)) end
  local a = opts.approval
  if a == true then field('"approval":true')
  elseif type(a) == "table" then
    field('"approval":true')
    if a.timeout ~= nil then field('"timeout_seconds":' .. format_("%d", trigger_timeout(a.timeout))) end
  elseif a ~= nil and a ~= false then error("ci.trigger: approval is true or { timeout = \"24h\" }", 2) end
  if opts.params ~= nil then
    if type(opts.params) ~= "table" then error("ci.trigger: params is a table of names and values", 2) end
    local ps = {}
    for k, v in stable_pairs(opts.params) do
      if type(k) ~= "string" then error("ci.trigger: a parameter is named by a string", 2) end
      if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then error("ci.trigger: parameter " .. k .. " is a string, a number or a boolean", 2) end
      ps[#ps + 1] = jstr(k) .. ":" .. jstr(tostring_(v))
    end
    field('"params":{' .. tconcat(ps, ",") .. "}")
  end
  out[#out + 1] = "}"
  return call("trigger", tconcat(out))
end

G.ci = {
  trigger = trigger,
  now = function() return tonumber(call("now", "")) end,
  random = function() return tonumber(call("random", "")) end,
  sleep = function(seconds)
    if type(seconds) ~= "number" then error("ci.sleep: number expected", 2) end
    call("sleep", tostring_(seconds))
  end,
  parallel = parallel,
  matrix = matrix,
  finally = function(fn)
    if type(fn) ~= "function" then error("ci.finally: a function expected", 2) end
    if cur.path ~= "m" then error("ci.finally: only in main, not inside a branch of ci.parallel", 2) end
    if #finals >= 16 then error("ci.finally: at most 16 cleanups", 2) end
    finals[#finals + 1] = fn
  end,
  pipeline = function(spec) return spec end,  -- metadata phase, pure, not journaled (PIP-002)
  string = param_ctor("string"), number = param_ctor("number"), bool = param_ctor("bool"), choice = param_ctor("choice"),
  single = setmetatable({}, {
    -- `ci.single["a"]{ ... }` runs one job (D-67): the id is the index, the steps are a list or a function. It waits for its steps and returns { status = "ok", steps = { [id] = result } }.
    __index = function(_, id)
      local jid = norm_ref(id, JOB_ID_WIDTH, "ci.single")
      return function(opts)
        if type(opts) ~= "table" then error("ci.single[\"" .. jid .. "\"]: a table expected", 2) end
        for k in rawnext, opts do
          if not JOB_FIELDS[k] then error("ci.single[\"" .. jid .. "\"]: unknown field '" .. tostring_(k) .. "'", 2) end
        end
        check_name(opts.name, "ci.single")
        local list, body = opts.steps, opts.body
        if (list == nil) == (body == nil) then error("ci.single[\"" .. jid .. "\"]: exactly one of steps (a list of step.sh[\"id\"]{ ... }) and body (a function) is given", 2) end
        if list ~= nil and type(list) ~= "table" then error("ci.single[\"" .. jid .. "\"]: steps is a list of steps", 2) end
        if body ~= nil and type(body) ~= "function" then error("ci.single[\"" .. jid .. "\"]: body is a function", 2) end
        local line = getline()
        -- the ids of the steps of a list are all known before one runs: a repeated id fails the run before a Pod is made
        if list ~= nil then
          local seen = {}
          for n = 1, rawlen(list) do
            local d = list[n]
            if type(d) ~= "table" or not steps_made[d] then error("ci.single[\"" .. jid .. "\"]: steps[" .. n .. "] is not a step made by step.sh[\"id\"]{ ... }", 2) end
            if seen[d.id] then error("duplicate_id: the step id '" .. d.id .. "' is used in the job '" .. jid .. "' at line " .. seen[d.id] .. " and again at line " .. d.line, 0) end
            seen[d.id] = d.line
          end
        end
        claim_job(jid, line)
        local results = setmetatable({}, { __index = function(t, k) local nk = try_ref(k, STEP_ID_WIDTH) if nk and nk ~= k then return rawget(t, nk) end end })
        local j = setmetatable({ __key = jid, __no = id_number(jid), __step_ids = {}, __results = results, __image = opts.image or "", __profile = norm_profile(opts.profile), __metrics = norm_metrics(opts.metrics),
          __mask = norm_mask(opts.mask), __timeout = norm_timeout(opts.timeout), __workspace = norm_workspace(opts.workspace), __shm = norm_shm(opts.shm), __secrets = norm_secrets(opts.secrets, 3), __artifacts = norm_artifacts(opts.artifacts, 3),
          __env = merge_env(pipeline_env, norm_env(opts.env, "ci.single env", 3), "ci.single env"), __cache = norm_cache(opts.cache, 3) }, Job_mt)
        local lock = norm_lock(opts.lock)
        if lock and cur.path ~= "m" then error("ci.single: a lock inside a branch of ci.parallel is not supported yet", 2) end
        if lock then call("lock", lock .. "\t" .. j.__key) end   -- the run waits here, suspended, until the lock is its turn; the job is named so that the lock can show who holds it
        local ok, err = pcall(function()
          if list ~= nil then
            for n = 1, rawlen(list) do j:run(list[n]) end
          else
            body(j)
          end
        end)
        if lock then call("unlock", lock) end           -- also when the job ended with an error
        if not ok then error(err, 0) end
        return { status = "ok", steps = results }
      end
    end,
    __call = function() error("ci.single: the id is the index: ci.single[\"a\"]{ image = ..., steps = { step.sh[\"a\"]{ cmd = ... } } }", 2) end,
  }),
  -- (the names below are not keys of `ci`, they answer through the metatable: `ci.step` is `step`, and `ci.job` says it is gone)
}
setmetatable(G.ci, { __index = function(_, k)
  if k == "step" then return step end
  if k == "job" then
    return function() error("ci.job is gone (D-67): a job is ci.single[\"a\"]{ image = ..., steps = { step.sh[\"a\"]{ cmd = ... } } } (or body = function(j) ... end, with j:run(step.sh[...]{ ... }))", 2) end
  end
end })

-- `run` is the argument for a real (`ci.pipeline`) script's `main(run)`; a script that returns a
-- plain value directly, as the sandbox test fixtures do, is unaffected.
local function run_main(fn, run)
  state.main = running()
  local given = rawget(run, "__given") or {}
  rawset(run, "__given", nil)
  -- D-63: where the script was read from, if it came from a repository. The core hands it over among the launch parameters under names that no parameter can have; it is not a
  -- parameter, so it leaves `given` here, and `run.source` always exists (empty strings for a script that came in the request).
  local source = { repository = "", commit = "", path = "", base = "" }      -- base (D-82): the commit of the last run of this pipeline that ended OK, "" when there is none
  for _, k in ipairs({ "repository", "commit", "path", "base" }) do
    local v = given["@source." .. k]
    if v ~= nil then source[k] = v; given["@source." .. k] = nil end
  end
  run.source = source
  local v = fn()
  if type(v) == "table" and type(rawget(v, "main")) == "function" then
    pipeline_env = norm_env(rawget(v, "env"), "ci.pipeline env", 0)
    local typed, json = resolve_params(rawget(v, "params"), given)
    if json ~= "" then call("params", json) end
    run.params = typed
    -- `ci.finally` (RUN-006): the cleanups registered while `main` ran are run when it ends, by success or by error, last registered first. The run ends with main's error if it
    -- had one, else with the first error of a cleanup; every cleanup is tried. The end of the run by a limit (a repeated id, too many steps) is not cleaned up after.
    local ok, res = pcall(v.main, run)
    local function fatal(e) return type(e) == "string" and (e:find("duplicate_id:", 1, true) or e:find("step_limit:", 1, true)) end
    if not ok and fatal(res) then error(res, 0) end
    local later_ok, later = true, nil
    for i = #finals, 1, -1 do
      local fok, ferr = pcall(finals[i])
      if not fok then
        if fatal(ferr) then error(ferr, 0) end
        if later_ok then later_ok, later = false, ferr end
      end
    end
    if not ok then error(res, 0) end
    if not later_ok then error(later, 0) end
    return res
  end
  return v
end

rawset(G, "step", step)
rawset(G, "_G", proxy)
return proxy, run_main
