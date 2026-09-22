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

local function run_main(fn)
  state.main = running()
  return fn()
end

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

G.ci = {
  now = function() return tonumber(call("now", "")) end,
  random = function() return tonumber(call("random", "")) end,
  sleep = function(seconds)
    if type(seconds) ~= "number" then error("ci.sleep: number expected", 2) end
    call("sleep", tostring_(seconds))
  end,
  sh = function(cmd)
    if type(cmd) ~= "string" then error("ci.sh: string expected", 2) end
    local code, out = call("sh", cmd):match("^(%-?%d+)\n(.*)$")
    return { exit = tonumber(code), outputs = out }
  end,
}

rawset(G, "_G", proxy)
return proxy, run_main
