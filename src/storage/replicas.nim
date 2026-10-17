## What the repair of a mirrored store needs from the mirror (storage/repair.nim): which nodes there are, and one thing at a time done on one node or between two. The mirror of the HTTP nodes
## (storage/httpstore.nim) is a `ReplicaBackend`.
import ../common/storagebackend

type
  MissedProc* = proc (key, node, op: string) {.gcsafe.}    ## a node did not take a write or a delete (`op` is `copy` or `delete`): the core puts it in the repair queue

  Probe* = object
    ok*, retry*, notFound*: bool
    size*: int64
    error*: string

  ReplicaBackend* = ref object of ObjectBackend

method nodeNames*(b: ReplicaBackend): seq[string] {.base.} = @[]
  ## the nodes, in the order of the settings; `onMissed` and the repair queue name a node by this
method sizeOn*(b: ReplicaBackend; node: int; key: string): Probe {.base.} = Probe(retry: false, error: "not implemented")
  ## whether node number `node` has the object, and its size
method deleteOn*(b: ReplicaBackend; node: int; key: string): Outcome {.base.} = fail("not implemented")
method copyBetween*(b: ReplicaBackend; src, dst: int; key: string): Outcome {.base.} = fail("not implemented")
  ## the object from node `src` onto node `dst`, whole, checked on the way

proc indexOf*(b: ReplicaBackend; name: string): int =
  let names = b.nodeNames()
  for i, n in names:
    if n == name: return i
  -1
