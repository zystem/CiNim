## Application metrics declared in the pipeline (Lua `metrics = {...}`, docs/metrics.md). The Lua sandbox validates the
## declaration and hands the shim one canonical JSON string; this module reads it back and turns what an application's
## own endpoint returns into a bounded list of samples. Pure (text in, samples out): the HTTP scrape and the JVM reader
## are layered on top (and are the only parts that need the application's cooperation / libraries - see docs/metrics.md).
##
## Limits are the defence against a runaway application: only `maxSamples` per scrape and `maxBytes` of response are
## looked at, names are checked, labels are dropped. The shim is not a metrics store, it relays a few numbers.
import std/[json, strutils, options]

const
  maxSamples* = 200            ## per scrape target
  maxBytes* = 1 shl 20         ## of one response

type
  Scrape* = object
    name*, url*, format*: string          ## format: prometheus | expvar
    interval*, timeout*: int
    patterns*: seq[string]  ## the declaration's `include` (a Nim keyword)
  Declaration* = object
    runtime*: string                       ## auto | jvm | none
    scrapes*: seq[Scrape]
  Sample* = object
    name*: string
    value*: float

proc parseDeclaration*(text: string): Option[Declaration] =
  ## "" (no declaration) or anything malformed -> none: a broken declaration must never stop the step's command.
  if text.len == 0: return
  try:
    let j = parseJson(text)
    var d = Declaration(runtime: j{"runtime"}.getStr("none"))
    for s in j{"scrape"}.getElems:
      var sc = Scrape(name: s["name"].getStr, url: s["url"].getStr, format: s{"format"}.getStr("prometheus"),
                      interval: s{"interval"}.getInt(15), timeout: s{"timeout"}.getInt(5))
      for p in s{"include"}.getElems: sc.patterns.add p.getStr
      d.scrapes.add sc
    result = some d
  except CatchableError:
    discard

func wildcardMatch*(pattern, name: string): bool =
  ## '*' matches any run of characters; everything else literally.
  var p, n = 0
  var star = -1
  var mark = 0
  while n < name.len:
    if p < pattern.len and pattern[p] == '*':
      star = p
      mark = n
      inc p
    elif p < pattern.len and pattern[p] == name[n]:
      inc p
      inc n
    elif star >= 0:
      p = star + 1
      inc mark
      n = mark
    else:
      return false
  while p < pattern.len and pattern[p] == '*': inc p
  p == pattern.len

func allowed(name: string; patterns: seq[string]): bool =
  if patterns.len == 0: return true
  for p in patterns:
    if wildcardMatch(p, name): return true

func validName(n: string): bool =
  n.len > 0 and n.len <= 200 and n[0] in {'a'..'z', 'A'..'Z', '_', ':'} and
    n.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', ':'})

func parsePrometheus*(text: string; patterns: seq[string]): seq[Sample] =
  ## Prometheus text exposition. Comments, labels, timestamps and non-finite values are dropped (a Pod's few samples are
  ## aggregated by core; per-label series would multiply without bound). A name with several label sets keeps the sum.
  var seen: seq[string]
  for rawLine in text[0 ..< min(text.len, maxBytes)].splitLines:
    let line = rawLine.strip
    if line.len == 0 or line[0] == '#': continue
    var nameEnd = 0
    while nameEnd < line.len and line[nameEnd] notin {' ', '\t', '{'}: inc nameEnd
    let name = line[0 ..< nameEnd]
    if not validName(name) or not allowed(name, patterns): continue
    var rest = line[nameEnd .. ^1]
    if rest.startsWith("{"):
      let close = rest.rfind('}')
      if close < 0: continue
      rest = rest[close + 1 .. ^1]
    let fields = rest.splitWhitespace
    if fields.len == 0: continue
    var v: float
    try: v = parseFloat(fields[0]) except ValueError: continue
    if v != v or v == Inf or v == -Inf: continue
    let at = seen.find(name)
    if at >= 0: result[at].value += v
    elif result.len < maxSamples:
      seen.add name
      result.add Sample(name: name, value: v)

proc parseExpvar*(text: string; patterns: seq[string]): seq[Sample] =
  ## Go's /debug/vars: nested numbers become `go_<path>` (memstats.Alloc -> go_memstats_alloc); arrays, strings and
  ## the bulky Sys/BySize/PauseNs members are skipped.
  proc walk(j: JsonNode; prefix: string; acc: var seq[Sample]) =
    if acc.len >= maxSamples: return
    case j.kind
    of JInt, JFloat:
      let n = prefix.toLowerAscii
      if validName(n) and allowed(n, patterns): acc.add Sample(name: n, value: j.getFloat)
    of JObject:
      for k, v in j:
        if k in ["cmdline", "BySize", "PauseNs", "PauseEnd"]: continue
        let key = k.multiReplace((".", "_"), ("-", "_"), (" ", "_"))
        walk(v, prefix & "_" & key, acc)
    else: discard
  try:
    walk(parseJson(text[0 ..< min(text.len, maxBytes)]), "go", result)
  except CatchableError:
    result = @[]
