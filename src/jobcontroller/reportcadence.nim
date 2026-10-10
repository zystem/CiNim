## When a controller reports its state to the core on the push channel (docs/conductors.md section 12). Pure.
## A report is a snapshot (ends, the Pods it sees, volumes released) and the core handles it with a handful of database queries, so a controller
## sends one when something changed, when the core asks for its state again, and otherwise only as a heartbeat. Work comes the other way, pushed
## by the core, and needs no report to ask for it.
import std/algorithm

const heartbeatSeconds* = 5.0

type
  Cadence* = object
    lastAt*: float          ## when the last report was sent (0: never)
    lastSig*: string        ## the picture of the Pods it carried
  Changes* = object
    transitions*, handedBack*, released*: bool    ## news that only a report can carry
    asked*: bool                                  ## the core said `resync`

func reportDue*(c: Cadence; now: float; news: Changes; sig: string): bool =
  c.lastAt == 0.0 or news.transitions or news.handedBack or news.released or news.asked or sig != c.lastSig or
    now - c.lastAt >= heartbeatSeconds

proc sent*(c: var Cadence; now: float; sig: string) =
  c.lastAt = now
  c.lastSig = sig

func podSignature*(pods: seq[(string, string, string)]): string =
  ## name, phase and reason of every Pod, in a fixed order: equal when the picture of the Pods is equal
  var parts: seq[string]
  for (name, phase, reason) in pods: parts.add name & "|" & phase & "|" & reason
  parts.sort()
  for p in parts: result.add p & ";"
