## The router's registry (SHD-006, D-39): the organisations that the cores register, kept in memory with a time to live, and the
## availability history of every core (one cell per minute). Pure data and logic, no I/O and no clock of its own - every call takes `now`
## (epoch seconds) - so the rules are unit-tested (tests/unit/trouter.nim).
import std/[tables, strutils, algorithm]

const
  maxCores* = 256               ## E-003: every table is bounded
  maxOrgsPerCore* = 1000
  maxFieldLen* = 256

type
  OrgEntry* = object
    slug*, name*, url*: string

  Core = object
    orgs: seq[OrgEntry]
    lastSeen: int64
    cells: seq[bool]            ## one cell per minute, oldest first: was a registration within the time to live at that minute

  Registry* = object
    ttl*: int64                 ## router.ttl, seconds
    history*: int               ## cells kept per core (1 440 = 24 hours)
    cores: OrderedTable[string, Core]

  ListItem* = object            ## one organisation in the answer of GET /list
    slug*, name*, url*, core*: string
    lastSeen*: int64

  CoreStatus* = object          ## one core on the page and in the metrics
    id*: string
    up*: bool
    lastSeen*: int64
    orgs*: int
    cells*: seq[bool]

func newRegistry*(ttl: int64 = 300; history = 1440): Registry =
  Registry(ttl: ttl, history: history)

func validCoreId*(s: string): bool =
  if s.len == 0 or s.len > 64: return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', ':', '-'}: return false
  true

func validSlug*(s: string): bool =
  ## a DNS label: the router only checks the shape, the core owns the rules (SHD-001)
  if s.len == 0 or s.len > 63 or s[0] == '-' or s[^1] == '-': return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc post*(r: var Registry; coreId: string; orgs: seq[OrgEntry]; now: int64): string =
  ## A POST replaces the whole list of that core and renews its time to live. Returns "" when accepted, otherwise the reason.
  if not validCoreId(coreId): return "core must be 1..64 characters of [A-Za-z0-9._:-]"
  if orgs.len > maxOrgsPerCore: return "at most " & $maxOrgsPerCore & " organisations per core"
  var seen: seq[string]
  for o in orgs:
    if not validSlug(o.slug): return "invalid slug: " & o.slug.substr(0, 63)
    if o.slug in seen: return "slug listed twice: " & o.slug
    seen.add o.slug
    if o.name.len > maxFieldLen or o.url.len > maxFieldLen: return "name and url are at most " & $maxFieldLen & " characters"
    if o.url.len > 0 and not (o.url.startsWith("https://") or o.url.startsWith("http://")): return "url must be http(s)"
  if coreId notin r.cores:
    if r.cores.len >= maxCores: return "too many cores"
    r.cores[coreId] = Core(lastSeen: now)
  r.cores[coreId].orgs = orgs
  r.cores[coreId].lastSeen = now
  ""

func isUp(r: Registry; c: Core; now: int64): bool = now - c.lastSeen <= r.ttl

proc list*(r: Registry; now: int64): seq[ListItem] =
  ## the organisations of the cores whose registration has not expired; an organisation that two cores list appears twice (the
  ## cores use that to find duplicates, SHD-006), sorted by slug and then by core
  for id, c in r.cores:
    if r.isUp(c, now):
      for o in c.orgs:
        result.add ListItem(slug: o.slug, name: o.name, url: o.url, core: id, lastSeen: c.lastSeen)
  result.sort(proc (a, b: ListItem): int = cmp((a.slug, a.core), (b.slug, b.core)))

proc status*(r: Registry; now: int64): seq[CoreStatus] =
  for id, c in r.cores:
    result.add CoreStatus(id: id, up: r.isUp(c, now), lastSeen: c.lastSeen, orgs: c.orgs.len, cells: c.cells)
  result.sort(proc (a, b: CoreStatus): int = cmp(a.id, b.id))

proc tick*(r: var Registry; now: int64) =
  ## once a minute: one availability cell per core; a core nobody has heard of for the whole history is forgotten
  var gone: seq[string]
  for id, c in r.cores.mpairs:
    c.cells.add r.isUp(c, now)
    if c.cells.len > r.history: c.cells.delete(0)
    if now - c.lastSeen > r.history.int64 * 60: gone.add id
  for id in gone: r.cores.del id

func upShare*(cells: seq[bool]): float =
  if cells.len == 0: return 0.0
  var up = 0
  for c in cells:
    if c: inc up
  up / cells.len
