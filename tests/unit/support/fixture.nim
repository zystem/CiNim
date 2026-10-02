## Shared pipeline script and deterministic fake host for journal/replay tests.
import std/options

const scriptSrc* = """
local t0 = ci.now()
local r = ci.sh("echo one")
local acc = {}
for i = 1, 3 do
  acc[#acc + 1] = string.format("%.3f", ci.random())
end
local ok = pcall(function()
  local r2 = ci.sh("fail")
  if r2.exit ~= 0 then error("step failed") end
end)
local r3 = ci.sh("echo " .. r.outputs)
return table.concat(acc, ",") .. "|" .. tostring(ok) .. "|" .. r3.outputs .. "|" .. t0
"""

const fixtureCalls* = 7  ## host calls made by scriptSrc

proc fakeHost*(seq: int; kind, payload: string): Option[string] =
  ## Result is a pure function of the call, so a resumed run must equal a clean one.
  case kind
  of "now": some($(1000 + seq))
  of "random": some($(seq) & ".25")
  of "sh":
    if payload == "fail": some("1\nboom")
    else: some("0\nout" & $seq)
  else: some("")
