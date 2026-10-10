## How many cores this Pod has: its CPU limit (cgroup) if it has one, else the cores of the node it may use (docs/conductors.md section 12). The
## number of workers of the core's hub is taken from it. `countProcessors` alone would say how many cores the *node* has, which a Pod limited to two
## CPUs must not take for its own.
import std/[strutils, cpuinfo, math]

func parseCpuMax*(text: string): int =
  ## cgroup v2 `cpu.max`: "<quota> <period>" or "max <period>"; 0 = no limit (or unreadable)
  let parts = text.strip.splitWhitespace
  if parts.len < 2 or parts[0] == "max": return 0
  try:
    let quota = parseInt(parts[0])
    let period = parseInt(parts[1])
    if quota <= 0 or period <= 0: return 0
    max(1, int(ceil(quota / period)))
  except ValueError: 0

func parseCfs*(quota, period: string): int =
  ## cgroup v1 `cpu.cfs_quota_us` and `cpu.cfs_period_us`; a quota of -1 is no limit
  try:
    let q = parseInt(quota.strip)
    let p = parseInt(period.strip)
    if q <= 0 or p <= 0: return 0
    max(1, int(ceil(q / p)))
  except ValueError: 0

proc readFirst(path: string): string =
  try: readFile(path)
  except IOError: ""

proc podCores*(): int =
  ## the CPU limit of this Pod; else the cores the process may run on
  var n = parseCpuMax(readFirst("/sys/fs/cgroup/cpu.max"))
  if n == 0: n = parseCfs(readFirst("/sys/fs/cgroup/cpu/cpu.cfs_quota_us"), readFirst("/sys/fs/cgroup/cpu/cpu.cfs_period_us"))
  if n == 0: n = countProcessors()
  max(1, n)

proc workerCount*(env = ""): int =
  ## the number of workers of the hub: `env` (CINIM_STREAM_WORKERS) if it is a positive number, else the cores of the Pod; at most 64
  var n = 0
  try: n = parseInt(env.strip)
  except ValueError: n = 0
  if n <= 0: n = podCores()
  min(max(n, 1), 64)
