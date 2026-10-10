## The lease of a run (RUN-008, docs/conductors.md section 6). Pure.
##
## A run is leased to one executor at a time. Granting a lease makes the next *attempt* (a number kept with the run) and the token
## `<attempt>.<HMAC-SHA256 of the run and the attempt under the core's key>`: nothing but the attempt and the expiry is stored, and a token
## cannot be made up or used for another run. Every call of the executor carries it. The core accepts a call only of the current attempt, so an
## executor that was believed lost (its lease ran out and another took the run) is refused when it comes back; and it accepts the holder
## whose lease ran out as long as nobody has taken the run since. The lease is given back when the executor suspends the run or finishes it.
import std/strutils
import crunchy
import ../common/ctrlauth

const leaseTtlSeconds* = 60

type
  LeaseState* = object
    attempt*: int          ## the attempt of the last lease granted (0: never leased)
    until*: int64          ## when it runs out; 0: not held (given back)
  LeaseVerdict* = enum
    lvOk
    lvForged               ## not a token of this run
    lvStale                ## the token of an earlier attempt: someone else has had the run since
    lvReleased             ## the current attempt, but the lease was given back

func hex(a: array[32, uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

proc leaseToken*(master, runId: string; attempt: int): string =
  $attempt & "." & hex(hmacSha256(master, "cinim/lease/v1|" & runId & "|" & $attempt))

func leaseAttempt*(token: string): int =
  ## the attempt a token claims; 0 if it is not shaped like a token
  let dot = token.find('.')
  if dot < 1 or token.len - dot - 1 != 64: return 0
  try: result = max(parseInt(token[0 ..< dot]), 0)
  except ValueError: result = 0

func canTake*(s: LeaseState; now: int64): bool =
  s.until == 0 or s.until < now

proc checkLease*(master, runId, token: string; s: LeaseState; now: int64): LeaseVerdict =
  let attempt = leaseAttempt(token)
  if attempt == 0 or not constantTimeEqual(token, leaseToken(master, runId, attempt)): return lvForged
  if attempt != s.attempt: return lvStale
  if s.until == 0: return lvReleased
  lvOk

func renewDue*(s: LeaseState; now: int64; ttl = leaseTtlSeconds): bool =
  ## write the lease again when half of it is gone (not at each call: the database is written at most twice per lease)
  s.until - now < ttl div 2
