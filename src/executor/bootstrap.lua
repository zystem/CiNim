-- Sandbox bootstrap: runs once with the real globals, returns the read-only
-- environment table that user scripts see as _ENV (PIP-005).
local G = _G
local type, error, rawget, rawset, rawlen, rawnext = type, error, rawget, rawset, rawlen, next
local getmetatable, setmetatable, tostring_ = getmetatable, setmetatable, tostring
local mtype = math.type
local tsort = table.sort
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

-- Host API: each call yields (kind, payload) to the Nim driver, which either
-- replays the journaled result or performs the call (PIP-003).
local yield_, running = coroutine.yield, coroutine.running
local state = {}

local function call(kind, payload)
  if running() ~= state.main then
    error("ci." .. kind .. ": host calls are not supported inside nested coroutines", 3)
  end
  return yield_(kind, payload)
end

coroutine.yield = function(...)
  if running() == state.main then
    error("coroutine.yield is reserved for host calls in the main script", 2)
  end
  return yield_(...)
end

-- Lua API v1 (6.7, lua/stdlib/cicd.d.lua), stage-1 subset: ci.pipeline, ci.job, Job:sh. One
-- `Job:sh` call is one step (RUN-002); `ci.job` itself is plain Lua control flow, not a host call,
-- same as `for`/`pcall` are not journaled --- only what a job's steps actually do is (PIP-003).
-- `matrix`, `parallel`, `use`, `ci.input`, services and secrets are not implemented yet.
local job_seq = 0

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

-- The execution profile of a job (RUN-004): "" is the organisation's ordinary one, "build" the build profile (A.13), whose steps run
-- as build Pods in the organisation's own namespace (D-42). Core refuses a profile that the shard does not have.
local function norm_profile(v)
  if v == nil or v == "default" then return "" end
  if v ~= "build" then error("ci.job: profile must be \"default\" or \"build\"", 3) end
  return v
end

-- The step's options reach the shim as one canonical JSON object (keys sorted, only what is set): "" when nothing is.
local function step_opts(job, opts)
  local metrics, mask, timeout = job.__metrics, job.__mask, job.__timeout
  local secrets = job.__secrets
  if opts then
    if opts.secrets ~= nil then secrets = merge_secrets(secrets, norm_secrets(opts.secrets, 4)) end
    if opts.metrics ~= nil then metrics = norm_metrics(opts.metrics) end
    if opts.mask ~= nil then mask = norm_mask(opts.mask) end
    if opts.timeout ~= nil then timeout = norm_timeout(opts.timeout) end
  end
  local parts = {}
  if mask ~= "" then parts[#parts + 1] = '"mask":' .. mask end
  if metrics ~= "" then parts[#parts + 1] = '"metrics":' .. metrics end
  if secrets and #secrets > 0 then parts[#parts + 1] = '"secrets":' .. secrets_json(secrets) end
  if timeout then parts[#parts + 1] = '"timeout":' .. timeout end
  if #parts == 0 then return "" end
  return "{" .. table.concat(parts, ",") .. "}"
end

local Job_mt = { __index = {
  sh = function(self, cmd, opts)
    if type(cmd) ~= "string" then error("Job:sh: string expected", 2) end
    -- payload: job key, image, profile ("" = the ordinary one), canonical options JSON ("" = none) and the command, tab-separated; the
    -- command is last because it may itself contain tabs (core splits into five fields)
    if opts and opts.ignore_failure ~= nil and type(opts.ignore_failure) ~= "boolean" then error("Job:sh: ignore_failure must be a boolean", 2) end
    local code, out = call("job_sh", self.__key .. "\t" .. self.__image .. "\t" .. self.__profile .. "\t" .. step_opts(self, opts) .. "\t" .. cmd):match("^(%-?%d+)\n(.*)$")
    code = tonumber(code)
    -- a non-zero code fails the job (and so the run, unless the script catches the error); `ignore_failure = true` returns it instead
    -- (6.7, ShOpts.ignore_failure). The code is in the journal, so a replay fails at the same call.
    if code ~= 0 and not (opts and opts.ignore_failure) then error("step failed with code " .. tostring(code), 2) end
    return { code = code, outputs = {}, stdout = (opts and opts.capture) and out or nil }
  end,
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

G.ci = {
  now = function() return tonumber(call("now", "")) end,
  random = function() return tonumber(call("random", "")) end,
  sleep = function(seconds)
    if type(seconds) ~= "number" then error("ci.sleep: number expected", 2) end
    call("sleep", tostring_(seconds))
  end,
  sh = function(cmd)  -- test fixture surface only (tests/unit); real pipelines use Job:sh
    if type(cmd) ~= "string" then error("ci.sh: string expected", 2) end
    local code, out = call("sh", cmd):match("^(%-?%d+)\n(.*)$")
    return { exit = tonumber(code), outputs = out }
  end,
  pipeline = function(spec) return spec end,  -- metadata phase, pure, not journaled (PIP-002)
  string = param_ctor("string"), number = param_ctor("number"), bool = param_ctor("bool"), choice = param_ctor("choice"),
  job = function(opts, fn)
    if type(opts) ~= "table" then error("ci.job: table expected", 2) end
    if type(fn) ~= "function" then error("ci.job: function expected", 2) end
    job_seq = job_seq + 1
    local j = setmetatable({ __key = "job-" .. job_seq, __image = opts.image or "", __profile = norm_profile(opts.profile), __metrics = norm_metrics(opts.metrics),
      __mask = norm_mask(opts.mask), __timeout = norm_timeout(opts.timeout), __secrets = norm_secrets(opts.secrets, 3) }, Job_mt)
    local ok, err = pcall(fn, j)
    if not ok then error(err, 0) end
    return { ok = true, outputs = {} }
  end,
}

-- `run` is the argument for a real (`ci.pipeline`) script's `main(run)`; a script that returns a
-- plain value directly, as the sandbox test fixtures do, is unaffected.
local function run_main(fn, run)
  state.main = running()
  local given = rawget(run, "__given") or {}
  rawset(run, "__given", nil)
  local v = fn()
  if type(v) == "table" and type(rawget(v, "main")) == "function" then
    local typed, json = resolve_params(rawget(v, "params"), given)
    if json ~= "" then call("params", json) end
    run.params = typed
    return v.main(run)
  end
  return v
end

rawset(G, "_G", proxy)
return proxy, run_main
