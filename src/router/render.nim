## What the router shows (SHD-006): the page with the organisations and the availability chart (server-side SVG with a table
## alternative, UI-006, no JS), the JSON list for the cores and the Prometheus text. Pure functions over the registry.
import std/[json, strutils, times]
import ../ui/render
import registry

const cellPx = 0.5          ## 1 440 cells make a 720 px strip

func listJson*(r: Registry; now: int64): string =
  var arr = newJArray()
  for i in r.list(now):
    arr.add %*{"slug": i.slug, "name": i.name, "url": i.url, "core": i.core, "last_seen": i.lastSeen}
  $(%*{"organizations": arr, "generated_at": now})

func ago(now, t: int64): string =
  let d = now - t
  if d < 60: $d & " s ago"
  elif d < 3600: $(d div 60) & " min ago"
  else: $(d div 3600) & " h ago"

func stripSvg(cells: seq[bool]; history: int): string =
  ## runs of equal cells become one rectangle, so the picture stays small however long the history is
  let w = int(history.float * cellPx)
  result = "<svg role=\"img\" aria-label=\"availability, last 24 hours\" width=\"" & $w & "\" height=\"16\" viewBox=\"0 0 " & $w & " 16\">" &
    "<rect width=\"" & $w & "\" height=\"16\" fill=\"#ddd\"/>"
  # the newest cell is at the right edge, a missing past (a young core) stays grey
  let offset = history - cells.len
  var i = 0
  while i < cells.len:
    var j = i
    while j + 1 < cells.len and cells[j + 1] == cells[i]: inc j
    let x = (offset + i).float * cellPx
    let width = (j - i + 1).float * cellPx
    result.add "<rect x=\"" & formatFloat(x, ffDecimal, 1) & "\" width=\"" & formatFloat(width, ffDecimal, 1) & "\" height=\"16\" fill=\"" &
      (if cells[i]: "#2a9d4b" else: "#c0392b") & "\"/>"
    i = j + 1
  result.add "</svg>"

proc renderPage*(r: Registry; now: int64): string =
  let orgs = r.list(now)
  let cores = r.status(now)
  var upOf: seq[(string, bool)]
  for c in cores: upOf.add (c.id, c.up)
  result = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" &
    "<meta http-equiv=\"refresh\" content=\"60\"><title>Organisations</title>" &
    "<style>body{font:16px system-ui,sans-serif;margin:1rem 16px;max-width:60rem}table{border-collapse:collapse;width:100%;margin:.5rem 0 1.5rem}" &
    "th,td{text-align:left;padding:.25rem .5rem;border-bottom:1px solid #ccc}.up{color:#1f7a3a}.down{color:#a93226}</style></head><body>" &
    "<h1>Organisations</h1>"
  if orgs.len == 0:
    result.add "<p>No organisation is registered.</p>"
  else:
    result.add "<table><thead><tr><th>Organisation</th><th>Name</th><th>Core</th></tr></thead><tbody>"
    for o in orgs:
      let link = if o.url.len > 0: "<a href=\"" & h(o.url) & "\">" & h(o.slug) & "</a>" else: h(o.slug)
      result.add "<tr><td>" & raw(link) & "</td><td>" & h(o.name) & "</td><td>" & h(o.core) & "</td></tr>"
    result.add "</tbody></table>"
  result.add "<h2>Availability</h2>"
  if cores.len == 0:
    result.add "<p>No core has registered yet.</p>"
  else:
    result.add "<table><thead><tr><th>Core</th><th>State</th><th>Last seen</th><th>Organisations</th><th>Last 24 hours</th></tr></thead><tbody>"
    for c in cores:
      let share = int(upShare(c.cells) * 100.0 + 0.5)
      result.add "<tr><td>" & h(c.id) & "</td><td class=\"" & (if c.up: "up" else: "down") & "\">" & (if c.up: "up" else: "down") &
        "</td><td>" & h(ago(now, c.lastSeen)) & "</td><td>" & h(c.orgs) & "</td><td>" & raw(stripSvg(c.cells, r.history)) &
        "<br><small>" & (if c.cells.len == 0: "no history yet" else: h(share) & " % up over " & h(c.cells.len) & " min") & "</small></td></tr>"
    result.add "</tbody></table>"
  result.add "<p><small>Generated " & h(fromUnix(now).utc.format("yyyy-MM-dd HH:mm:ss")) & " UTC. A core counts as up while its last registration is not older than " &
    h(int(r.ttl)) & " s.</small></p></body></html>"

proc renderMetrics*(r: Registry; now: int64): string =
  result = "# HELP cinim_router_core_up 1 if the core registered within the time to live\n# TYPE cinim_router_core_up gauge\n"
  for c in r.status(now):
    result.add "cinim_router_core_up{core=\"" & c.id & "\"} " & (if c.up: "1" else: "0") & "\n"
  result.add "# TYPE cinim_router_organizations gauge\ncinim_router_organizations " & $r.list(now).len & "\n"
