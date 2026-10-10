## docs/conductors.md section 12: the hub of the core has as many workers as the Pod has cores - the CPU limit of the Pod if it has one, else the cores of
## the node it may use. Pure parsers of the cgroup files; the reading itself is tried on this machine.
import std/unittest
import common/podcpu

suite "the cores of a Pod":
  test "cgroup v2: 'max' means no limit, otherwise quota over period rounded up":
    check parseCpuMax("max 100000") == 0
    check parseCpuMax("max 100000\n") == 0
    check parseCpuMax("200000 100000") == 2
    check parseCpuMax("150000 100000") == 2         # a limit of 1.5 CPU is two cores' worth of threads
    check parseCpuMax("50000 100000") == 1          # half a CPU is one
    check parseCpuMax("400000 100000\n") == 4
  test "cgroup v1: quota -1 means no limit":
    check parseCfs("-1", "100000") == 0
    check parseCfs("300000", "100000") == 3
    check parseCfs("100000", "100000") == 1
  test "anything unreadable is no limit":
    check parseCpuMax("") == 0
    check parseCpuMax("garbage") == 0
    check parseCpuMax("100 0") == 0                   # a period of zero
    check parseCfs("x", "y") == 0
  test "the number of workers is at least 1 and at most 64, and the environment overrides it":
    check workerCount(env = "") in 1 .. 64
    check workerCount(env = "4") == 4
    check workerCount(env = "0") in 1 .. 64           # zero is not a number of workers: the default
    check workerCount(env = "1000") == 64
    check workerCount(env = "abc") in 1 .. 64
