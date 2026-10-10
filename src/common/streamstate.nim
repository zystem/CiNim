## The bookkeeping of the push channel (docs/conductors.md section 12). Pure; the sockets are in common/stream.nim.
##
## The core pushes numbered frames to a client; the client says in every frame it sends which number it has applied (a cumulative
## acknowledgement). What is not acknowledged is sent again after a reconnect or after a while, and the receiver applies a frame only if it
## is the next number: once and in order, whatever the network does. The actions behind the frames are idempotent anyway (deterministic Pod
## names, step keys, run attempts), so a duplicate that gets through would be harmless; this keeps it from getting through.
import std/algorithm

type
  Sent* = object
    id*: uint64
    kind*, payload*: string
    sentAt*: float
  Outbox* = object
    nextId: uint64
    unacked*: seq[Sent]          ## in the order of their numbers
  Inbox* = object
    applied: uint64              ## the highest number applied, in order
  Accept* = enum
    acApply                      ## the next frame: apply it
    acDuplicate                  ## already applied: ignore it
    acGap                        ## a number is missing before it: do not apply, the acknowledgement asks for the rest
  Credit* = object
    available*: int              ## how much more the receiver says it can take

func initOutbox*(): Outbox = Outbox(nextId: 1)
func initInbox*(): Inbox = Inbox()

proc push*(o: var Outbox; kind, payload: string; now: float): Sent =
  ## number a frame and keep it until it is acknowledged
  result = Sent(id: o.nextId, kind: kind, payload: payload, sentAt: now)
  inc o.nextId
  o.unacked.add result

proc ack*(o: var Outbox; upTo: uint64) =
  ## the peer has applied everything up to `upTo`
  var keep: seq[Sent]
  for s in o.unacked:
    if s.id > upTo: keep.add s
  o.unacked = keep

func due*(o: Outbox; now, olderThan: float): seq[Sent] =
  ## the frames sent more than `olderThan` seconds ago that nobody has acknowledged
  for s in o.unacked:
    if now - s.sentAt > olderThan: result.add s

proc sentAgain*(o: var Outbox; ids: seq[uint64]; now: float) =
  for s in o.unacked.mitems:
    if s.id in ids: s.sentAt = now

proc accept*(i: var Inbox; id: uint64): Accept =
  if id == i.applied + 1:
    i.applied = id
    acApply
  elif id <= i.applied: acDuplicate
  else: acGap

func ackValue*(i: Inbox): uint64 = i.applied

proc set*(c: var Credit; n: int) = c.available = max(n, 0)

proc take*(c: var Credit; n: int): int =
  ## use up to `n` of the credit; how much was really available
  result = min(max(n, 0), c.available)
  c.available -= result
