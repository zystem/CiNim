## Shared pipeline script and deterministic fake host for journal/replay tests.
import std/[options, strutils]

const scriptSrc* = """
local function sh(cmd)
  local out
  ci.job({image = "x"}, function(j) out = j:sh(cmd, {capture = true, ignore_failure = true}) end)
  return out
end
local t0 = ci.now()
local r = sh("echo one")
local acc = {}
for i = 1, 3 do
  acc[#acc + 1] = string.format("%.3f", ci.random())
end
local ok = pcall(function()
  local r2 = sh("fail")
  if r2.code ~= 0 then error("step failed") end
end)
local r3 = sh("echo " .. r.stdout)
return table.concat(acc, ",") .. "|" .. tostring(ok) .. "|" .. r3.stdout .. "|" .. t0
"""

const fixtureCalls* = 7  ## host calls made by scriptSrc

proc fakeHost*(seq: int; kind, payload: string): Option[string] =
  ## Result is a pure function of the call, so a resumed run must equal a clean one.
  case kind
  of "now": some($(1000 + seq))
  of "random": some($(seq) & ".25")
  of "job_sh":
    if payload.endsWith("\tfail"): some("1\nboom")
    else: some("0\nout" & $seq)
  else: some("")
